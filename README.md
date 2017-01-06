Synopsis
======
This 0-configuration tinc implementation is designed to supplement flanneld to provide point-to-point encryption for container traffic.

It operates as a normal tinc VPN, but is compatible with early-docker which allows the main docker daemon to use the correct configuration, even during initial provisioning when using tinc to secure flanneld.

Requirements
======
This docker container requires a running etcd2 instance, listening on localhost:4001 without SSL.

Required Docker Flags
======
```
--net=host               We must share the host's network stack.
-v /etc/tinc:/etc/tinc   We must store the configuration files in a persistent location.
--cap-add NET_ADMIN      We must be allowed to create network devices.
--device /dev/net/tun    We must be given access to the tunnel device.
```

Network Information
======

Server instances are assigned an IP address from the `172.16.0.0/13` address space. It is recommended that you configure flannel to use the other half of the address space (`172.24.0.0/13`)
```
Address:   172.16.0.0            10101100.00010 000.00000000.00000000
Netmask:   255.248.0.0 = 13      11111111.11111 000.00000000.00000000
Wildcard:  0.7.255.255           00000000.00000 111.11111111.11111111

Network:   172.16.0.0/13         10101100.00010 000.00000000.00000000 (Class B)
Broadcast: 172.23.255.255        10101100.00010 111.11111111.11111111
HostMin:   172.16.0.1            10101100.00010 000.00000000.00000001
HostMax:   172.23.255.254        10101100.00010 111.11111111.11111110
Hosts/Net: 524,286               (Private Internet)
```

Example Service Unit
======
```
[Unit]
Description=tinc vpn
Requires=early-docker.service etcd2.service
After=early-docker.service
Before=flanneld.service

[Service]
Restart=always
RestartSec=10
ExecStartPre=-/bin/docker -H unix:///var/run/early-docker.sock rm tinc
ExecStartPre=-/bin/docker -H unix:///var/run/early-docker.sock pull ahrotahntee/automatic-tinc:latest
ExecStart=/bin/docker -H unix:///var/run/early-docker.sock run --name tinc --net=host -v /etc/tinc:/etc/tinc --cap-add NET_ADMIN --device /dev/net/tun ahrotahntee/automatic-tinc:latest
ExecStop=/bin/docker -H unix:///var/run/early-docker.sock stop tinc

[Install]
WantedBy=early-docker.target
```

```
[Unit]
Description=tinc vpn
Requires=etcd2.service
After=etcd2.service
Before=flanneld.service

[Service]
Restart=always
RestartSec=10
ExecStartPre=-/bin/rkt rm tinc
ExecStart=/bin/rkt run --name tinc --insecure-options=paths,image --net=host --dns 8.8.8.8 docker://ahrotahntee/automatic-tinc:latest --caps-retain CAP_NET_ADMIN,CAP_NET_BIND_SERVICE
ExecStop=/bin/rkt stop tinc

[Install]
WantedBy=network-online.target
