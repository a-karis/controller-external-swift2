#!/bin/bash
###########################################################
#
# Point haproxy to external swift proxies
# 2016, akaris@redhat.com
#
###########################################################

date +'%F %H:%M:%S' > /tmp/swift-haproxy-runtime.txt
echo "$ACTION" >> /tmp/swift-haproxy-runtime.txt
echo "$DEPLOY_UUID" >> /tmp/swift-haproxy-runtime.txt

# only execute on controllers
# assumption: if rabbitmq is running, then this is a controller node
# also check hostnames
if `ps aux | grep -q "[r]abbitmq-server"` || 
   `hostname | grep -iq "control"` ||
   `hostname | grep -iq "ctrl"`;then
  echo "This is a controller" >> /tmp/swift-haproxy-runtime.txt
else
  echo "This is not a controller, aborting script" >> /tmp/swift-haproxy-runtime.txt
  exit 0
fi

# get these from heat
swift_proxy_names=($SWIFT_PROXY_NAMES)
swift_proxy_ips=($SWIFT_PROXY_IPS)
storage_net_cidr="$STORAGE_NET_CIDR"
external_net_cidr="$EXTERNAL_NET_CIDR"
# get all VIPs which are configured on pacemaker
pacemaker_vips=`pcs status | grep 'ip-' | awk '{print $1}' | sed 's/ip-//g' | tr '\n' ' '`

# create new swift_proxy_server VIP and pool for haproxy.cfg
ha_proxy_str=""
ha_proxy_str="${ha_proxy_str}listen swift_proxy_server\n"
# check all pacemaker vips - only listen on this VIP if it's in the storage network or external network
for vip in $pacemaker_vips;do
  if `ruby -e "require 'ipaddr';exit IPAddr.new('$storage_net_cidr').include?('$vip')"` ||
     `ruby -e "require 'ipaddr';exit IPAddr.new('$external_net_cidr').include?('$vip')"`;then
    ha_proxy_str="${ha_proxy_str}  bind $vip:8080 transparent\n"
  fi
done
# add swift proxy servers to this pool haproxy
for ((i=0; i < ${#swift_proxy_ips[@]}; i++));do
  ha_proxy_str="${ha_proxy_str}  server ${swift_proxy_names[$i]} ${swift_proxy_ips[$i]}:8080 check fall 5 inter 2000 rise 2\n"
done
# create temporary file with config
echo -e $ha_proxy_str > /tmp/swift-haproxy.txt

# copy haproxy.cfg to temporary file and filter (=delete) any previous swift_proxy_server section
write_line=true
lead='listen swift_proxy_server'
> /tmp/haproxy.cfg
cat /etc/haproxy/haproxy.cfg | while read line;do
  if [ "$line" == "$lead" ];then
    write_line=false
  elif [ "$line" == "" ];then
    write_line=true
  fi
  if $write_line;then
    echo $line >> /tmp/haproxy.cfg
  fi
done
# now merge clean haproxy.cfg with new load balancer config for swift
cat /tmp/swift-haproxy.txt >> /tmp/haproxy.cfg
cp -f /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg

# stop openstack-swift services and disable them on startup
# we don't want this to throw an error and make our deployment fail, so pipe stderr to /dev/null
systemctl list-units | grep openstack-swift | awk '{print $1}' | xargs -I {} systemctl stop {} 1>/dev/null 2>&1
systemctl list-units | grep openstack-swift | awk '{print $1}' | xargs -I {} systemctl disable {} 1>/dev/null 2>&1

# restart haproxy-clone resource and resource cleanup
# we don't want this to throw an error and make our deployment fail, so pipe stderr to /dev/null
# start it in background, give it max. 5 minutes to complete, and kill
# this is a workaround, because the pcs resource restart hung during a test
pcs resource restart haproxy-clone 1>/dev/null 2>&1 &
PID_OF_PCS_RESTART=$!
if `echo "$PID_OF_PCS_RESTART" | egrep -q '[0-9]+'`;then
  c=0
  while [ $c -lt 300 ];do
    sleep 1;
    if ! `ps aux | awk '{print $2}' | grep -q "$PID_OF_PCS_RESTART"`;then
      break
    fi
    c=$[ $c + 1 ]
  done
  kill -9 $PID_OF_PCS_RESTART 1>/dev/null 2>&1 
fi

pcs resource cleanup 1>/dev/null 2>&1

exit 0
