#!/bin/bash

set -e

if [[ $UID != 0 ]]; then
    echo "Please run this script with sudo:"
    echo "sudo $0 $*"
    exit 1
fi

if [ "$1" == "server" ]; then
  SERVER=1
elif [ "$1" == "client" ] && [ ! -z "$2" ]; then
  SERVER_IP=$2
else
  cat <<EOF
Usage:
  install.sh server
  install.sh client {any consul host in the network}
EOF
  exit 1
fi

# Install required packages
apt-get update
apt-get install unzip

# Install Docker
if [ ! -f /usr/bin/docker ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  apt-key fingerprint 0EBFCD88
  add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"
  apt-get update
  apt-get install docker-ce -y
fi

# Install Consul
if [ ! -f /usr/bin/consul ]; then
  wget https://releases.hashicorp.com/consul/1.0.1/consul_1.0.1_linux_amd64.zip -O consul.zip
  unzip consul.zip
  rm consul.zip
  mv consul /usr/bin/consul

  cat > /etc/systemd/system/consul.service <<'EOF'
[Unit]
Description=Consul
Documentation=https://consul.io/docs/

[Service]
ExecStart=/bin/sh -c "exec /usr/bin/consul agent -advertise=$( ip route get 1 | awk '{print $NF;exit}' ) -recursor=\"$(grep -Pom2 '^nameserver \K.+' /etc/resolv.conf | tail -1)\" -config-dir=/etc/consul"
ExecReload=/bin/kill -HUP $MAINPID
LimitNOFILE=65536
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable consul
fi

# Install Nomad
if [ ! -f /usr/bin/nomad ]; then
  wget https://releases.hashicorp.com/nomad/0.7.1-rc1/nomad_0.7.1-rc1_linux_amd64.zip -O nomad.zip
  unzip nomad.zip
  rm nomad.zip
  mv nomad /usr/bin/nomad

  cat > /etc/systemd/system/nomad.service <<'EOF'
[Unit]
Description=Nomad
Documentation=https://nomadproject.io/docs/

[Service]
ExecStart=/bin/sh -c "exec /usr/bin/nomad agent -config /etc/nomad"
ExecReload=/bin/kill -HUP $MAINPID
LimitNOFILE=65536
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable nomad
fi

# Remove old config files
rm -rf /etc/nomad /etc/consul /var/lib/nomad /var/lib/consul

# Create required directories
mkdir -p /etc/nomad
mkdir -p /etc/consul
mkdir -p /var/lib/nomad
mkdir -p /var/lib/consul

# Create config files
if [ $SERVER ]; then

  cat > /etc/nomad/server.hcl <<EOF
data_dir = "/var/lib/nomad"

server {
  enabled = true
  bootstrap_expect = 1
}
EOF

  cat > /etc/consul/server.hcl<<'EOF'
server = true
ui = true
data_dir =  "/var/lib/consul"
bootstrap_expect = 1
ports {
  dns = 53
}
EOF

else

  cat > /etc/nomad/client.hcl <<EOF
data_dir = "/var/lib/nomad/"

client {
  enabled = true
  servers = ["nomad.service.consul:4647"]
}
EOF

  cat > /etc/consul/client.hcl<<EOF
data_dir = "/var/lib/consul"
retry_join = ["$SERVER_IP"]
ports {
  dns = 53
}
EOF

fi

systemctl restart nomad consul

# Point DNS server to the local consul
echo "nameserver 127.0.0.1" > /etc/resolvconf/resolv.conf.d/head
resolvconf -u

