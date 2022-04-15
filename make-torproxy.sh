#!/bin/bash

############################
# Tor Proxy/Gateway builder 
# build n tor / proxy nodes as required
# designed to work on debian/ubuntu
# - SS
############################

####### ARG DEFAULTS #######

PROXYPORT="3128"
LOADBAL="round-robin"
NODES="3"
LOG="/dev/null"

usage() {
    cat << EOF

    Note: Run as root. Will flush existing iptables.
    Required: tor, privoxy, squid3, iptables.

    usage: $0 OPTIONS

    OPTIONS:
      -h        help
      -n NUM    number of nodes (default: ${NODES})
      -p PORT   aggregating proxy port (default: ${PROXYPORT})
      -l FILE   specify log file
      -K        just kill existing tor, privoy, squid processes 
 
    SQUID LOAD BALANCE OPTIONS:
      -r        round-robin (default)
      -c        CARP array
      -s        source ip hash

    GW IPTABLES OPTIONS:
      -N        Non-random gateway

EOF
}

####### DEFAULTS #######
KILLONLY=false

####### TOR DEFAULTS #######
TORDATA_PATH="/run/tor"
TRANSPORT_BASE="10000"
SOCKSPORT_BASE="9500"
PRIVOXYPORT_BASE="8500"

####### PRIVOXY DEFAULTS #######
PRIVOXYCONFIG_PATH="/tmp"

####### PRIVOXY DEFAULTS #######
SQUIDCONFIG_PATH="/tmp"

####### IPTABLES DEFAULTS #######
ROPT=true


while getopts "hn:p:l:rwcsNK" OPTION
do
    case $OPTION in
        h)
            usage; exit 1;;
        n)
            NODES=$OPTARG;;
        p)
            PORXYPORT=$OPTARG;;
        l)
            LOGFILE=$OPTARG;;
        r)
            LOADBAL="round-robin";;
        c)
            LOADBAL="carp";;
        c)
            LOADBAL="sourcehash";;
        N)
            ROPT=false;;
        K)
            KILLONLY=true;;
    esac
done


###### CHECK COMMANDS EXIST ######
cmdexist() {
    CMDS=($@)
    missing=false
    for c in ${CMDS[@]}
    do
        if ! type $c >/dev/null 2>&1;  then
            echo "Need to install ${c}"
            missing=true
        fi
    done
    if $missing; then
        exit 1
    fi

}

###### KILL EXISTING PROCESSES #######
killexisting() {
    PROCESS=($@)
    echo "Killing existing ${PROCESS[*]} processes"
    for p in ${PROCESS[@]}
    do 
        PLIST=$(pgrep $p)
        for i in ${PLIST[@]}
        do
            echo "killing ${p} pid ${i}"
            kill -9 "$i"
        done
    done
    
    #Remove previous squid cache peer settings
    echo "Removing squid localhost settings"
    sed -i '/localhost[0-9]/d' /etc/hosts
}

CMDLIST=( "tor" "privoxy" "squid3" )

###### IF JUST KILL EXISTING SETUP ######
if $KILLONLY; then
    killexisting ${CMDLIST[@]}
    exit 0
fi

####### ARG CHECK #######
if ! [[ $NODES ]]; then
    echo "Err: Number of Tor nodes to build required"
    exit 1
fi

####### LOGFILE CHECK #######
if ! [[ $LOGFILE ]]; then
    LOGFILE=$LOG;
fi

####### CHECK COMMANDS ARE INSTALLED #######
cmdexist ${CMDLIST[@]}

####### KILL EXISTING PROCESSES #######
killexisting ${CMDLIST[@]}

####### FLUSH IPTABLES #######
iptables -t nat -F
iptables -F

####### NETWORK INFO #######
INTERFACE=$(ip addr show | grep eth0 | grep inet | tr -s " " | cut -f3 -d " ")
IP=$(echo $INTERFACE | cut -f1 -d"/")
CIDR=$(echo $INTERFACE | cut -f2 -d"/")
NETWORK="$(echo $IP | cut -f1,2,3 -d".").0/${CIDR}"

####### PRIVOXY CONFIG BASE #######
PRIVOXY_BASE=$(cat <<EOF
socket-timeout 300
keep-alive-timeout 5
toggle 0
EOF
)

####### SQUID CONFIG BASE #######
####### SQUID < 3.2 #######
SQUID_LT32=$(cat <<EOF
acl manager proto cache_object
acl localhost src 127.0.0.1 ::1
EOF
)

####### SQUID > 3.2 #######
SQUID_BASE=$(cat <<EOF
acl network src $NETWORK 
acl SSL_ports port 443
acl Safe_ports port 80 
acl Safe_ports port 443
acl CONNECT method CONNECT
http_port $PROXYPORT
never_direct allow all
http_access allow network
http_access allow manager localhost
http_access deny manager
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localhost
cache deny all
EOF
)
    SQUID_VERSION=$(squid3 -v | head -n1 | egrep -o '[0-9]+\.[0-9]+' | head -n1)
    if [[ $(echo "$SQUID_VERSION < 3.2" | bc) = 1 ]]; then
        echo "$SQUID_LT32" > /tmp/squid.conf
        echo "$SQUID_BASE" >> /tmp/squid.conf
        echo "old"
    else
        echo "$SQUID_BASE" > /tmp/squid.conf
        echo "new"
    fi

echo "--------------------------------"
for ((n=0;n<$NODES;n++)) 
do

####### CREATE TOR DATA DIRECTORIES #######
    if [[ ! -e $TORDATA_PATH ]]; then
        mkdir -p -m 2700 "${TORDATA_PATH}/${n}"
        chown debian-tor:debian-tor "${TORDATA_PATH}/${n}"
    fi
    # if [[ ! -e $TORDATA_PATH/$n ]]; then
    #     mkdir -m 2700 "${TORDATA_PATH}/${n}"
    # fi
    # if [[ $(stat -c %U:%G $TORDATA_PATH/$n) != "debian-tor:debian-tor" ]]; then
    #     chown debian-tor:debian-tor "${TORDATA_PATH}/${n}"
    # fi


####### LAUNCH TOR DAEMONS #######
    echo -n "Launching Tor node: ${IP}:$((SOCKSPORT_BASE+n)).."
    if tor --RunAsDaemon 1 --DataDirectory "${TORDATA_PATH}/${n}" --SocksPort $((SOCKSPORT_BASE+n)) \
        --VirtualAddrNetwork "10.192.0.0/10" --TransPort $((TRANSPORT_BASE+n)) \
        --TransListenAddress "${IP}" --DNSPort "53" --DNSListenAddress "${IP}" 2>&1 > "$LOGFILE"; then
        echo "Succeeded"
    else
        echo "Tor Node: ${IP}:$((SOCKSPORT_BASE+n)) Failed"
    fi


####### CREATE PRIVOXY CONFIG #######
PRIVOXY_ADD=$(cat <<EOF
listen-address  127.0.0.1:$((PRIVOXYPORT_BASE+n))
forward-socks5   /  127.0.0.1:$((SOCKSPORT_BASE+n)) .
EOF
)
    echo "$PRIVOXY_BASE" > $PRIVOXYCONFIG_PATH/config-$n
    echo "$PRIVOXY_ADD" >> $PRIVOXYCONFIG_PATH/config-$n

####### LAUNCH PRIVOXY DAEMONS #######
    echo -n "Launching Privoxy bridge: ${IP}:$((PRIVOXYPORT_BASE+n)).."
    if privoxy $PRIVOXYCONFIG_PATH/config-$n; then
        echo "Succeeded"
    else
        echo "Privoxy bridge: ${IP}:$((PRIVOXYPORT_BASE+n)) Failed"
    fi

####### ADDITIONAL SQUID CONFIG #######
SQUID_ADD=$(cat <<EOF
cache_peer localhost${n} parent $((PRIVOXYPORT_BASE+n)) 0 $LOADBAL no-query
EOF
)
    echo "$SQUID_ADD" >> $SQUIDCONFIG_PATH/squid.conf

####### /etc/hosts CONFIG #######
    # This supports the squid cache_peers
    if ! [[ $(grep "localhost${n}$" /etc/hosts) ]]; then
        echo "127.0.0.1 localhost${n}" >> /etc/hosts
    fi

done

sleep 2
echo "--------------------------------"

####### LAUNCH SQUID DAEMON #######
echo -n "Launching Squid Proxy: ${IP}:${PROXYPORT} (connect here).."
if squid3 -f "${SQUIDCONFIG_PATH}/squid.conf"; then
    echo "Succeeded"
else
    echo "Squid Proxy: ${IP}:${PROXYPORT} failed"
fi

####### IPTABLES TRANSPORT REDIRECT #######
if $ROPT; then 
    ROPT="--random" 
else
    ROPT=""
fi

echo -n "Defining Tor Gateway: (default gw ip) ${IP}.."
if iptables -t nat -A PREROUTING -i eth0 -p tcp -m multiport ! --dports  ${PROXYPORT},53,22 \
    -j REDIRECT --to-ports ${TRANSPORT_BASE}-$((TRANSPORT_BASE+NODES-1)) ${ROPT}; then
    echo "Succeeded"
else
    echo "Tor Gateway failed"
fi

