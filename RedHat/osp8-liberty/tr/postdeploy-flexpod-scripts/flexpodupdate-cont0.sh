#!/bin/bash -x

# NetApp Manila setup for cluster wide setup
# in a RHEL-OSP8 FlexPod environment. Executes on one 
# controller in a Pacemaker cluster.
# Intended to be run after all other extra Controller
# specific setup has been done.
#
# Generally this script is not executed directly by the customer, 
# but rather copied to provisioned nodes in the Overcloud and
# launched by the flexpodupdate-start.sh script on the OSP Director node.
#
# Copyright 2016 NetApp, Inc.
#  
# Contributors:
# Dave Cain, Original Author
#

# USER DEFINED CONSTANTS
# CHANGE THESE TO SUIT YOUR ENVIORNMENT
# Make sure MANILA_DB/USER PASSWORD is the same as configured
# with the flexpodupdate-controllers.sh script!

MANILA_DB_PASSWORD=fb3df31944a4bdad72c77ff2e0e4b3c808a3abbe
MANILA_USER_PASSWORD=d82f96db99bd3924b459455eaa20b9dbcea43934

# source needed environment variables (should already be there)
source /root/overcloudrc

#
# MANILA SETUP Cluster-wide
#

# create user for manila, a role, and service entities in keystone.
openstack user create --password $MANILA_USER_PASSWORD manila --project service --email nobody@example.com
openstack role add --project service --user manila admin
openstack service create --name manila --description "Manila File Share Service" share
openstack service create --name manilav2 --description "Manila File Share Service V2" sharev2

# create the database for manila
# - grant privileges and refresh immediately
mysql -u root -Bse "create database manila;" 
mysql -u root -Bse "grant all privileges on manila.* to manila@'localhost' identified by '$MANILA_DB_PASSWORD';" 
mysql -u root -Bse "grant all privileges on manila.* to manila@'%' identified by '$MANILA_DB_PASSWORD';" 
mysql -u root -Bse "flush privileges;" 

# initial synchronize of the database for manila
# - around 30 tables should be created here 
manila-manage db sync

# grab cinder's IP addresses so we can create manila's endpoint
MANILA_PUBLICIP=$(openstack endpoint show cinder | awk '/ publicurl /' | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
MANILA_INTERNALIP=$(openstack endpoint show cinder | awk '/ internalurl /' | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
MANILA_ADMINIP=$(openstack endpoint show cinder | awk '/ adminurl /' | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')

# create 2 endpoints for manila
openstack endpoint create --region regionOne share \
--publicurl http://$MANILA_PUBLICIP:8786/v1/%\(tenant_id\)s \
--internalurl http://$MANILA_INTERNALIP:8786/v1/%\(tenant_id\)s \
--adminurl http://$MANILA_ADMINIP:8786/v1/%\(tenant_id\)s

openstack endpoint create --region regionOne sharev2 \
--publicurl http://$MANILA_PUBLICIP:8786/v2/%\(tenant_id\)s \
--internalurl http://$MANILA_INTERNALIP:8786/v2/%\(tenant_id\)s \
--adminurl http://$MANILA_ADMINIP:8786/v2/%\(tenant_id\)s

# wait at least 30 seconds for cluster resources.
sleep 30

# create pacemaker resource records for the following:
# - manila-api -- active/active service
# - manila-scheduler -- active/active service
# - manila-share -- active/passive service
pcs resource create openstack-manila-api systemd:openstack-manila-api --clone interleave=true
pcs resource create openstack-manila-scheduler systemd:openstack-manila-scheduler --clone interleave=true
pcs resource create openstack-manila-share systemd:openstack-manila-share

pcs constraint order start openstack-manila-api-clone then openstack-manila-scheduler-clone
pcs constraint colocation add openstack-manila-scheduler-clone with openstack-manila-api-clone
pcs constraint order start openstack-manila-scheduler-clone then openstack-manila-share
pcs constraint colocation add openstack-manila-share with openstack-manila-scheduler-clone

# restart nova scheduler clusterwide due to DiskFilter bug
# See https://bugzilla.redhat.com/show_bug.cgi?id=1302074
if [ `hostname -s` == "overcloud-controller-0" ]; then
    pcs resource restart openstack-nova-scheduler
fi
