#!/bin/bash

set -o errexit

run_consul_server() {
  docker run -d \
    --name=consul-server-at-$(uname -n) \
    --hostname=$(uname -n) \
    -e 'CONSUL_LOCAL_CONFIG={"skip_leave_on_interrupt": true, "datacenter": "testDC", "acl_master_token": "95790f9c-3e98-46f5-967e-8f3ffb02194c", "acl_datacenter": "TestDC", "acl_default_policy": "allow", "acl_down_policy": "allow" }' \
    --net=host \
    -v /srv/consul/data:/consul/data \
    consul:0.7.5 agent -server -ui -bind=$(ip a s dev eth1 | awk '/inet / {split($2,a,"/"); print a[1]}') \
    -client 0.0.0.0 \
    -bootstrap-expect 3 \
    -retry-join 172.20.21.11 \
    -retry-join 172.20.21.12 \
    -retry-join 172.20.21.13 \
    -retry-interval 5s
}

run_consul_agent() {
  docker run -d \
    --name=consul-agent-at-$(uname -n) \
    --hostname=$(uname -n) \
    --net=host \
    -v /srv/consul/data:/consul/data \
    -e 'CONSUL_LOCAL_CONFIG={"datacenter": "testDC"}' \
    consul:0.7.5 agent -ui \
    -bind=$(ip a s dev eth1 | awk '/inet / {split($2,a,"/"); print a[1]}') \
    -client 0.0.0.0

  for i in `seq 1 10`; do
    sleep 1
    echo -n "."
  done

  docker exec consul-agent-at-$(uname -n) consul join 172.20.21.11
}

run_vault() {
  NODE_IP=$(ip a s dev eth1 | awk '/inet / {split($2,a,"/"); print a[1]}')
  docker run -d \
    --name=vault-at-$(uname -n) \
    --hostname=$(uname -n) \
    --net=host \
    --cap-add=IPC_LOCK \
    -e "VAULT_LOCAL_CONFIG={\"backend\": {\"consul\": { \"address\": \"${NODE_IP}:8500\", \"path\": \"vault\" }}, \"listener\": {\"tcp\": { \"address\": \"0.0.0.0:8200\", \"tls_disable\": \"1\"}}, \"default_lease_ttl\": \"168h\", \"max_lease_ttl\": \"720h\"}" \
    vault server
}

setup_glusterd() {
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
}

mount_glustervol() {
    mkdir -p /srv/portainer || :
    mount -t glusterfs $(uname -n):/glustervol1 /srv/portainer || :
    grep -q portainer /etc/fstab || echo "$(uname -n):/glustervol1   /srv/portainer    glusterfs defaults 0 0" >> /etc/fstab
}

init_swarm() {
  docker swarm init --advertise-addr $(ip a l dev eth1 | awk '/inet / { split($2, a, "/"); print a[1]}')
}

run_portainer_as_svc() {
  docker service create --name portainer \
    --publish 9000:9000 \
    --constraint 'node.role == manager' \
    --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
    --mount type=bind,src=/srv/portainer,dst=/data \
    portainer/portainer \
      -H unix:///var/run/docker.sock
}

run_consul_as_svc() {
  docker network create --driver overlay --subnet 172.21.0.0/24 consul

  docker service create \
    --network=consul \
    --name=consul \
    -e 'CONSUL_LOCAL_CONFIG={"skip_leave_on_interrupt": true, "datacenter": "testDC", "acl_master_token": "95790f9c-3e98-46f5-967e-8f3ffb02194c", "acl_datacenter": "TestDC", "acl_default_policy": "allow", "acl_down_policy": "allow"}' \
    -e 'CONSUL_BIND_INTERFACE=eth0' \
    --mode global \
    -p 8300-8302:8300-8302 \
    -p 8301-8302:8301-8302/udp \
    -p 8400:8400 \
    -p 8500:8500 \
    -p 8600:8600 \
    -p 8600:8600/udp \
    --mount type=bind,src=/srv/consul/data,dst=/consul/data \
    --hostname="{{.Service.Name}}-{{.Node.ID}}" \
    --constraint 'node.role == manager' \
    consul:0.7.5 agent -server -ui -client=0.0.0.0 \
    -bootstrap-expect 3 \
    -retry-join 172.21.0.3 \
    -retry-join 172.21.0.4 \
    -retry-join 172.21.0.5 \
    -retry-interval 5s
}
exec_join_workers() {
   WORKER_TOKEN=$(docker swarm join-token -q worker)
   NODE_IP=$(ip a s dev eth1 | awk '/inet / {split($2,a,"/"); print a[1]}')
   for n in manager{2,3} worker{1,2}; do
     ssh \
       -i /vagrant/.vagrant/machines/${n}/libvirt/private_key \
       -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
       vagrant@$n \
       sudo docker swarm join --token $WORKER_TOKEN ${NODE_IP}:2377
   done
}

exec_promote_managers() {
   for n in manager{2,3}; do
     docker node promote $n
   done
}
exec_gluster_sh() {
   for n in manager{2,3} worker{1,2}; do
     ssh \
       -i /vagrant/.vagrant/machines/${n}/libvirt/private_key \
       -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
       vagrant@$n \
       sudo /vagrant/gluster.sh
   done
}


### Main ###

case $(uname -n) in
  'manager1')
    setup_glusterd
    mount_glustervol
    init_swarm
    run_portainer_as_svc
    run_consul_server
    exec_join_workers
    exec_promote_managers
    exec_gluster_sh
    ;;
  'manager2' | 'manager3')
    mount_glustervol
    run_consul_server
    ;;
  'worker1' | 'worker2')
    run_consul_agent
    ;;
esac

run_vault
