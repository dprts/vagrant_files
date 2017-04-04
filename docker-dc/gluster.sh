#!/bin/bash

set -o errexit

if [ "$(uname -n)" == "manager1" ]; then
  set +o errexit
  gluster volume info glustervol1
  retval=$?
  set -o errexit
  if [ $retval -ne 0 ]; then
    gluster peer probe manager2 && sleep 1
    gluster peer probe manager3 && sleep 1
    gluster peer status

    gluster volume create glustervol1 replica 3 transport tcp \
      manager1:/bricks/brick1/brick \
      manager2:/bricks/brick1/brick \
      manager3:/bricks/brick1/brick

    gluster volume start glustervol1
    gluster volume info all
  fi
fi

mkdir -p /srv/portainer || :
mount -t glusterfs $(uname -n):/glustervol1 /srv/portainer || :

if [ "$(uname -n)" == "manager1" ]; then
  docker swarm init --advertise-addr $(ip a l dev eth1 | awk '/inet / { split($2, a, "/"); print a[1]}')
  docker service create --name portainer \
    --publish 9000:9000 \
    --constraint 'node.role == manager' \
    --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
    --mount type=bind,src=/srv/portainer,dst=/data \
    portainer/portainer \
      -H unix:///var/run/docker.sock

  docker network create --driver overlay --subnet 172.21.0.0/24 consul

  docker service create \
    --network=consul \
    --name=consul \
    -e 'CONSUL_LOCAL_CONFIG={"skip_leave_on_interrupt": true}' \
    -e 'CONSUL_BIND_INTERFACE=eth0' \
    --mode global \
    -p 8500:8500 \
    --mount type=bind,src=/srv/consul/data,dst=/consul/data \
    consul agent -server -ui -client=0.0.0.0 \
    -bootstrap-expect 3 \
    -retry-join 172.21.0.3 \
    -retry-join 172.21.0.4 \
    -retry-join 172.21.0.5 \
    -retry-interval 5s
fi
