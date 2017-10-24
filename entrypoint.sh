#!/bin/ash
set -x

firstAddr=0
lastAddr=4294967295
nextAddr=0
subnetMask=4294967295
assignmentComplete=false
networkName=$TINC_NETWORK_NAME
etcdPath=/tinc-vpn.org/$networkName

# Path Structure:
# /tinc-vpn.org/$networkName
# /tinc-vpn.org/$networkName/addresses/<IP-INT> Value: HOSTNAME
# /tinc-vpn.org/$networkName/configs/<HOSTNAME> Value: CONFIG DATA
# /tinc-vpn.org/$networkName/subnets/<IP-INT>/<SUBNET-MASK> <- Necessary?


HOSTNAME=$(hostname | tr - _)
PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)
PRIVATE_IP=127.0.0.1
SUBNET=255.255.255.255

DOTNO=$(expr index $HOSTNAME . - 1)
if [ $DOTNO -gt 0 ]; then
  HOSTNAME=${HOSTNAME:0:$DOTNO}
fi

function intToIP() {
	# Convert integer-IPs back to their useful normal form
	fOct=$((($1&4278190080)>>24))
	sOct=$((($1&16711680)>>16))
	tOct=$((($1&65280)>>8))
	lOct=$(($1&255))
	retVal="$fOct.$sOct.$tOct.$lOct"
	eval "$2='$retVal'"
}

function initalizeEtcd {
	# Initialize the etcd2 key-value store so we don't get errors when attempting to access empty sets
	echo [NOTICE] Initializing $etcdPath
	curl -sfX PUT "http://127.0.0.1:4001/v2/keys$etcdPath/addresses?dir=true&prevExist=false" >> /dev/null
	curl -sfX PUT "http://127.0.0.1:4001/v2/keys$etcdPath/configs?dir=true&prevExist=false" >> /dev/null
}

function defineRange() {
	# Convert IP to integer and perform bit math

	fOct=$(echo $1 | cut -d. -f1)
	sOct=$(echo $1 | cut -d. -f2)
	tOct=$(echo $1 | cut -d. -f3)
	lOct=$(echo $1 | cut -d. -f4 | cut -d/ -f1)
	net=$(echo $1 | cut -d/ -f2)

	ipInt=$(($fOct*16777216 + $sOct*65536 + $tOct*256 + $lOct))
	subnetMask=$((4294967295<<(32-$net)&4294967295))
	firstAddr=$((($ipInt&$subnetMask)+1))
	lastAddr=$((($firstAddr+2**(32-$net))-3))
	
	intToIP $subnetMask SUBNET
}

function waitOnKeyStore()
{
	# Wait for etcd2 to become available, since we're starting pretty
	# early in the boot process.
	while true; do
		STATUS=$(curl -sS http://127.0.0.1:4001/health | jq '.health' | tr -d '"')
		if [ "$STATUS" == "true" ]; then
			break
		fi
		sleep 5
	done
}

function allocateIP() {
	echo "[NOTICE] Looking for available IP in $2 ($1)"
	topAddr=$(($firstAddr))
	nextAddr=$(($topAddr))
	tIP=0

	usedAddrs=$(curl -s http://127.0.0.1:4001/v2/keys$etcdPath/addresses | jq '.node.nodes[].key' | cut -d/ -f5 | tr -d '"')
	if [ "${#usedAddrs[@]}" -gt 0 ]; then
		for addr in $usedAddrs; do
			if [ $addr -gt $topAddr ]; then
				topAddr=$addr
			fi
			addrs[$addr]="true"
		done

		topAddr=$(($topAddr+1))
	
		for x in `seq $firstAddr $topAddr`; do
			if [ "${addrs[$x]}" != "true" ]; then
				nextAddr=$x
				break
			fi
		done
	fi

	if [ $nextAddr -gt $lastAddr ]; then
		echo "[FATAL ] Address space exhausted"
		exit 1
	fi

	intToIP $nextAddr tIP	
	echo "         Attempting to Allocate IP: $tIP ($nextAddr)"
	status=$(curl -o /dev/null -w '%{http_code}' -s -XPUT http://127.0.0.1:4001/v2/keys$etcdPath/addresses/$nextAddr?prevExist=false -d value=$HOSTNAME)
	echo "         Status: $status"

	if [ $status -eq 201 ]; then
		echo '[NOTICE] Successfully Allocated IP'
		assignmentComplete=true
		intToIP $nextAddr PRIVATE_IP
	fi		
}

function writeConfigs {
	mkdir -p /etc/tinc/$networkName/hosts
	cat <<- EOF > /etc/tinc/$networkName/tinc.conf
	Name = $HOSTNAME
	AddressFamily = ipv4
	Interface = tun0
	EOF
	
	for peer in $PEERS; do
		echo "ConnectTo = ${peer:20:64}" >> /etc/tinc/$networkName/tinc.conf
	done

	cat <<- EOF > /etc/tinc/$networkName/tinc-up
	#!/bin/sh
	ifconfig tun0 $PRIVATE_IP netmask $SUBNET
	EOF

	cat <<- EOF > /etc/tinc/$networkName/tinc-down
	#!/bin/sh
	ifconfig tun0 down
	EOF

	cat <<- EOF > /etc/tinc/$networkName/hosts/$HOSTNAME
	Address = $PUBLIC_IP
	Subnet = $PRIVATE_IP/32
	EOF
}

publishConfig () {
	curl -Ss -XPUT "http://127.0.0.1:4001/v2/keys$etcdPath/configs/$HOSTNAME" --data-urlencode value@/etc/tinc/$networkName/hosts/$HOSTNAME
}

updatePeers () {
	echo "[NOTICE] Updating peer configs"
	CONFIG_DATA=$(curl -Ss "http://127.0.0.1:4001/v2/keys$etcdPath/configs?recursive=true")
	PEERS=$(echo $CONFIG_DATA | jq '.node.nodes[].key' | tr -d '"')
	for peer in $PEERS; do
		CONFIG=$(echo $CONFIG_DATA | jq '.node.nodes[] | select(.key =="'$peer'") | .value' | tr -d '"')
		echo -e $CONFIG > /etc/tinc/$networkName/hosts/${peer:35:64}
	done
}

function setup() {
	# Skip setup if we've already done this
	if [ -f /etc/tinc/$networkName/.setup-complete ]; then
		return 0
	fi

	# Perform Math & Magic
	initalizeEtcd
	defineRange $2

	while [ $assignmentComplete != "true" ]; do
		# assignmentComplete global set in allocateIP function
		allocateIP $1 $2
		sleep 1
	done
	
	writeConfigs
	
	# Set permissions & generate key
	chmod +x /etc/tinc/$networkName/tinc-up
	chmod +x /etc/tinc/$networkName/tinc-down
	tincd -n $networkName -K 4096 < /dev/null
	
	# Publish Configuration. NOTE: This causes all other notes to refresh
	publishConfig

	# Acknowledge that setup is complete
	touch /etc/tinc/$networkName/.setup-complete
	sleep 5
}

monitor () {
	# Monitor for changes to the config tree while we're running
	while true; do
		curl -Ss "http://127.0.0.1:4001/v2/keys$etcdPath/configs?wait=true&recursive=true"

		# Don't fetch peers if curl returns an error
		if [ $? -ne 0 ]; then
			sleep 1m
			continue
		fi

		updatePeers
		killall -HUP tincd
	done
}

# Wait for etcd2
waitOnKeyStore

# Perform Setup
setup $TINC_NETWORK_NAME $TINC_NETWORK_SUBNET

# Fetch peer list
updatePeers

# Start monitoring for new peers
monitor &

# Start Service
tincd -n $networkName -D &

# Trap signals
PID="$!"
trap "kill -INT $PID" SIGINT
trap "kill -ALRM $PID" SIGALRM
trap "kill -HUP $PID" SIGHUP
trap "kill -USR1 $PID" SIGUSR1
trap "kill -USR2 $PID" SIGUSR2
trap "kill -WINCH $PID" SIGWINCH

# Wait for service exit
wait $PID
