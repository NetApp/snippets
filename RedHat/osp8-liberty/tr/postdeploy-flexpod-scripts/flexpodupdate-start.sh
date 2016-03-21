#!/bin/bash -x
# FlexPod reference architecture post-deployment scriplet 
# - Pushes updated configuration to resulting overcloud deployment.
# - Meant to be used after OSP-Director (based on TripleO) is 
#   finished and successful.  Do not run otherwise.
#
# Pre-Requisites
# - Stack user is executing this script, with stackrc sourced.
# - Stack user executes this script directly, which in turn 
#   copies other scripts to the overcloud systems and 
#   launches them.
# - overcloudrc RC file is in the previous directory '../'.
#
# Running
# - Simply execute the script after the above pre-requisites 
#   are satisfied: './flexpodupdate-start.sh'
#
# Copyright 2016 NetApp, Inc.
#  
# Contributors:
# Dave Cain, Original Author
#

# apply generic but needed settings to all servers in the overcloud
# - subscription-manager registration (optional)
# - install Manila packages
# - rhel-osp8 engineering repositories
for iterator in $(openstack server list | awk '/ACTIVE/ {print $8}' | cut -f2 -d'=')
do
  scp -o StrictHostKeyChecking=no flexpodupdate-allsystems.sh heat-admin@${iterator}:/tmp/
  ssh heat-admin@${iterator} "sudo /tmp/flexpodupdate-allsystems.sh"
done

# apply specific settings to all the controllers in the overcloud
# - update manila packages on all controllers
# - copy NetApp Copy Offload Tool binary (customer must download from NetApp toolchest)
# - copy Overcloudrc file to get information about the running environment
for iterator in $(openstack server list | grep controller | awk '/ACTIVE/ {print $8}' | cut -f2 -d'=')
do
  scp -o StrictHostKeyChecking=no ../overcloudrc heat-admin@${iterator}:/tmp/
  scp -o StrictHostKeyChecking=no flexpodupdate-controllers.sh heat-admin@${iterator}:/tmp/
  scp -o StrictHostKeyChecking=no na_copyoffload_64 heat-admin@${iterator}:/tmp/
  ssh heat-admin@${iterator} "sudo /tmp/flexpodupdate-controllers.sh"
done

# apply cluster-wide settings to the first controller in the overcloud only
# - setup Manila galera DB (clustered)
# - setup Keystone entries for Manila
# - pacemaker entries for manila-{api,scheduler,share}
# - start and enable OpenStack Manila
for iterator in $(openstack server list | grep controller-0 | awk '/ACTIVE/ {print $8}' | cut -f2 -d'=')
do
  scp -o StrictHostKeyChecking=no flexpodupdate-cont0.sh heat-admin@${iterator}:/tmp/
  ssh heat-admin@${iterator} "sudo /tmp/flexpodupdate-cont0.sh"
done
