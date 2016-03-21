#!/bin/bash -x

# NetApp FlexPod setup for RHEL-OSP8 provisioned Overcloud
# Contains extra configuration items for an optimal setup.
#
# Generally this script is not executed directly by the customer, 
# but rather copied to provisioned nodes in the Overcloud and
# launched by the flexpodupate-start.sh script on the OSP Director node.
#
# Copyright 2016 NetApp, Inc.
#  
# Contributors:
# Dave Cain, Original Author
#

# subscribe to subscription manager & repos
#subscription-manager register --username davecain@netapp.com --password password 
#subscription-manager attach --pool blah
#subscription-manager repos  --disable=*
#subscription-manager repos --enable=rhel-7-server-rpms \
#     --enable=rhel-7-server-optional-rpms --enable=rhel-7-server-extras-rpms \
#     --enable=rhel-7-server-openstack-8.0-rpms \
#     --enable=rhel-ha-for-rhel-7-server-rpms \
#     --enable=rhel-7-server-rh-common-rpms

# update/install manila packages
yum update -y openstack-manila openstack-manila-share python-manila
yum install -y python-manilaclient
