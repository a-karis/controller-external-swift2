#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
template_base_dir="$DIR"

random=$(uuidgen)
# just to avoid that we replace in this script itself ... just in case it resides in template_base_dir ...
uuid_marker="UUID-"
find $template_base_dir -type f | xargs -I {} sed -i "s/###${uuid_marker}.*###/###${uuid_marker}${random}###/g" {}

openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml -e ${template_base_dir}/networks-additional/networks-additional-isolation.yaml -e ${template_base_dir}/network-environment.yaml --control-flavor control --compute-flavor compute --control-scale 3 --compute-scale 0 --ceph-storage-scale 0 --ntp-server 10.5.26.10 --neutron-network-type vxlan --neutron-tunnel-types vxlan
