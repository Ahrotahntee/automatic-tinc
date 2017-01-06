#!/bin/sh
#HOST_IP=$(ip route show | grep default | awk 'NR=1 {print $3}')
HOST_IP=127.0.0.1
HOSTNAME=$(hostname | tr - _)
DOTNO=$(expr index $HOSTNAME . - 1)
if [ $DOTNO -gt 0 ]; then
  HOSTNAME=${HOSTNAME:0:$DOTNO}
fi

publishConfig () {
  curl -XPUT "http://$HOST_IP:4001/v2/keys/tinc-vpn.org/peers/$HOSTNAME/config" --data-urlencode value@/etc/tinc/hosts/$HOSTNAME
  curl -XPUT "http://$HOST_IP:4001/v2/keys/tinc-vpn.org/peers/$HOSTNAME/private_ip" -d value=$PRIVATE_IP
}

updatePeers () {
  echo "[NOTICE] Updating peer configs"
  CONFIG_DATA=$(curl http://$HOST_IP:4001/v2/keys/tinc-vpn.org/peers?recursive=true)
  PEERS=$(echo $CONFIG_DATA | jq '.node.nodes[].key' | tr -d '"')
  for peer in $PEERS; do
    CONFIG=$(echo $CONFIG_DATA | jq '.node.nodes[] | select(.key == "'$peer'") | .nodes[] | select(.key == "'$peer/config'") | .value' | tr -d '"')
    echo -e $CONFIG > /etc/tinc/hosts/${peer:20:64}
  done
}

setup () {
  if [ -f /etc/tinc/.setup-complete ]; then
    return 0
  fi

  # Create initial structure (if not exist)
  mkdir /etc/tinc/hosts -p
  curl -XPUT "http://$HOST_IP:4001/v2/keys/tinc-vpn.org/peers/?dir=true&prevExist=false"
  curl -XPUT "http://$HOST_IP:4001/v2/keys/tinc-vpn.org/next_ip?prevExist=false" -d value=172.16.0.1
 
  # Retrieve the next available IP address
  export PRIVATE_IP=$(curl "http://$HOST_IP:4001/v2/keys/tinc-vpn.org/next_ip" | jq '.node.value' | tr -d '"')

  # Increment the next available IP address
  OV=$(echo $PRIVATE_IP | cut -d. -f2)
  MV=$(echo $PRIVATE_IP | cut -d. -f3)
  IV=$(echo $PRIVATE_IP | cut -d. -f4)
  while true; do
    echo "[NOTICE] This client will have IP $PRIVATE_IP"
    if [ $IV -eq 255 ]; then
      if [ $MV -eq 255 ]; then
        if [ $OV -eq 22 ]; then
          echo "[ ERROR] Out of address space!"
          exit
        fi
        OV=$(($OV+1))
        MV=1
      fi
      MV=$(($MV+1))
      IV=1
    else
      IV=$(($IV+1))
    fi
    NEXT_IP="172.$OV.$MV.$IV"

    # Instruct future clients that this IP is used
    echo "[NOTICE] Instructing etcd to reserve it"
    RESULT=$(curl -XPUT "http://$HOST_IP:4001/v2/keys/tinc-vpn.org/next_ip?prevValue=$PRIVATE_IP" -d value=$NEXT_IP | jq '.errorcode')
    if [ $RESULT == "101" ]; then
      echo "[NOTICE] Someone grabbed the IP address first, trying again"
      sleep 1
      continue
    fi
    break
  done

  updatePeers

  echo "[NOTICE] Building local configs"
  CONFIG_DATA=$(curl http://$HOST_IP:4001/v2/keys/tinc-vpn.org/peers?recursive=true)
  PEERS=$(echo $CONFIG_DATA | jq '.node.nodes[].key' | tr -d '"')
  PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)
  cat << EOF > /etc/tinc/tinc.conf
Name = $HOSTNAME
AddressFamily = ipv4
Interface = tun0
EOF

  for peer in $PEERS; do
    echo "ConnectTo = ${peer:20:64}" >> /etc/tinc/tinc.conf
  done

  cat << EOF > /etc/tinc/tinc-up
#!/bin/sh
ifconfig tun0 $PRIVATE_IP netmask 255.248.0.0
EOF

  cat << EOF > /etc/tinc/tinc-down
#!/bin/sh
ifconfig tun0 down
EOF

  cat << EOF > /etc/tinc/hosts/$HOSTNAME
Address = $PUBLIC_IP
Subnet = $PRIVATE_IP/32
EOF

  chmod +x /etc/tinc/tinc-up
  chmod +x /etc/tinc/tinc-down

  # Generate keys
  tincd -K 4096 < /dev/null

  publishConfig

  touch /etc/tinc/.setup-complete
}

start () {
  tincd -D
}

monitor () {
  while true; do
    curl "http://$HOST_IP:4001/v2/keys/tinc-vpn.org/peers/?wait=true&recursive=true"

    # Don't fetch peers if curl returns an error
    if [ $? -ne 0 ]; then
      sleep 1m
      continue
    fi

    updatePeers
    killall -HUP tincd
  done
}

setup
start &
PID="$!"
monitor &

trap "kill -INT $PID" SIGINT
trap "kill -ALRM $PID" SIGALRM
trap "kill -HUP $PID" SIGHUP
trap "kill -INT $PID" SIGINT
trap "kill -USR1 $PID" SIGUSR1
trap "kill -USR2 $PID" SIGUSR2
trap "kill -WINCH $PID" SIGWINCH
ps -a
echo "PID: $PID"
wait $PID
