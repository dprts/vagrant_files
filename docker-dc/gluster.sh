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
fi
