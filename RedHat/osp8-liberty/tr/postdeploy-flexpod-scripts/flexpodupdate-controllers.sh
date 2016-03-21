#!/bin/bash -x

# Extra NetApp FlexPod setup for RHEL-OSP8 Controllers
# Meant to be run on each Controller in the deployment.
# This assumes RHEL-OSP Director has first provisioned a functioning
# overcloud environment.  DO NOT run otherwise.
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
# with the flexpodupdate-cont0.sh script!

MANILA_DB_PASSWORD=fb3df31944a4bdad72c77ff2e0e4b3c808a3abbe
MANILA_USER_PASSWORD=d82f96db99bd3924b459455eaa20b9dbcea43934
NETAPP_CLUSTERADMIN_LIF=172.21.11.20
NETAPP_CLUSTERADMIN_USER=admin
NETAPP_CLUSTERADMIN_PASS=CHANGEME
NETAPP_MANILA_SVM=osp8-svm

# move overcloudrc file to /root directory for use later
mv /tmp/overcloudrc /root/

# source needed environment variables
source /root/overcloudrc

# move NetApp Copy Offload tool to /usr/local/bin directory
mv /tmp/na_copyoffload_64 /usr/local/bin/

#
# MANILA SETUP ON CONTROLLERS
#
# - Setup api, scheduler, and share on the Controllers.
# - Intent is manila-api = A/A, manila-scheduler=A/A
# - manila-share = A/P
#

# install manila-ui packages so horizon can see shares tab
# - Requires http restart for now, see: 
#   https://bugzilla.redhat.com/show_bug.cgi?id=1285516
yum install -y openstack-manila-ui

# create haproxy specific section for Manila
# - source ip addresses that cinder uses for Manila in HAProxy
MANILA_PUBLICIP=$(openstack endpoint show cinder | awk '/ publicurl /' | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
MANILA_INTERNALIP=$(openstack endpoint show cinder | awk '/ internalurl /' | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')

cat <<EOF >/etc/haproxy/manila.cfg
listen manila
bind $MANILA_PUBLICIP:8786
bind $MANILA_INTERNALIP:8786
EOF

# update haproxy and manila.conf oslo_messaging_rabbit stanza to account for rabbit hosts
# - also setup a new manila.cfg under haproxy for VIP specifics and
#   use sysconfig directive to pass a new cfg file.
RABBIT_HOSTS=( $(cat /etc/cinder/cinder.conf | grep rabbit_hosts | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' ) )

for (( i=0; i< ${#RABBIT_HOSTS[@]}; i++ )) do
    echo "server overcloud-controller-$i ${RABBIT_HOSTS[$i]}:8786 check fall 5 inter 2000 rise 2" >> /etc/haproxy/manila.cfg
done

echo "OPTIONS=\"-f /etc/haproxy/manila.cfg\"" > /etc/sysconfig/haproxy

# - commented out entries are generally defaults
#   and can be modified if so desired.
openstack-config --set /etc/manila/manila.conf oslo_messaging_rabbit rabbit_hosts $(echo ${RABBIT_HOSTS[@]} | tr ' ' ,)
#openstack-config --set /etc/manila/manila.conf oslo_messaging_rabbit rabbit_use_ssl False
#openstack-config --set /etc/manila/manila.conf oslo_messaging_rabbit rabbit_userid guest
#openstack-config --set /etc/manila/manila.conf oslo_messaging_rabbit rabbit_password guest
#openstack-config --set /etc/manila/manila.conf oslo_messaging_rabbit rabbit_port 5672
#openstack-config --set /etc/manila/manila.conf oslo_messaging_rabbit rabbit_virtual_host /
#openstack-config --set /etc/manila/manila.conf oslo_messaging_rabbit amqp_durable_queues false
openstack-config --set /etc/manila/manila.conf oslo_messaging_rabbit rabbit_ha_queues True
#openstack-config --set /etc/manila/manila.conf oslo_messaging_rabbit heartbeat_timeout_threshold 60
#openstack-config --set /etc/manila/manila.conf oslo_messaging_rabbit heartbeat_rate 2
openstack-config --set /etc/manila/manila.conf oslo_concurrency lock_path /var/lib/manila/tmp

# update manila.conf with pertinent information
# - set up the share listening process to be on the internal API network
# - set our MariaDB parameters to listen on VIP for
# - enable netapp share backend when it is configured next
# - update oslo_concurrency section
MYINTAPI_ADDR=( $(grep -v '^#' /etc/cinder/cinder.conf | grep osapi_volume_listen | awk '{print $3}' ) )
MYGLANCEAPI_VIP=( $(grep -v '^#' /etc/cinder/cinder.conf | grep glance_api_servers | awk '{print $3}' ) )
openstack-config --set /etc/manila/manila.conf DEFAULT debug true
openstack-config --set /etc/manila/manila.conf DEFAULT verbose true
openstack-config --set /etc/manila/manila.conf DEFAULT log_dir /var/log/manila
openstack-config --set /etc/manila/manila.conf DEFAULT use_syslog false
openstack-config --set /etc/manila/manila.conf DEFAULT osapi_share_listen $MYINTAPI_ADDR
openstack-config --set /etc/manila/manila.conf DEFAULT api_paste_config /etc/manila/api-paste.ini 
openstack-config --set /etc/manila/manila.conf DEFAULT state_path /var/lib/manila
openstack-config --set /etc/manila/manila.conf DEFAULT glance_api_servers $MYGLANCEAPI_VIP
#openstack-config --set /etc/manila/manila.conf DEFAULT sql_idle_timeout 3600
#openstack-config --set /etc/manila/manila.conf DEFAULT storage_availability_zone nova
openstack-config --set /etc/manila/manila.conf DEFAULT rootwrap_config /etc/manila/rootwrap.conf
#openstack-config --set /etc/manila/manila.conf DEFAULT auth_strategy keystone
openstack-config --set /etc/manila/manila.conf DEFAULT enabled_share_backends netapp
#openstack-config --set /etc/manila/manila.conf DEFAULT nova_catalog_info compute:nova:publicURL
#openstack-config --set /etc/manila/manila.conf DEFAULT nova_catalog_admin compute:nova:adminURL
#openstack-config --set /etc/manila/manila.conf DEFAULT network_api_class manila.network.neutron.neutron_network_plugin.NeutronNetworkPlugin
openstack-config --set /etc/manila/manila.conf DEFAULT rpc_backend rabbit
#openstack-config --set /etc/manila/manila.conf DEFAULT control_exchange openstack
openstack-config --set /etc/manila/manila.conf database connection mysql://manila:$MANILA_DB_PASSWORD@$MANILA_INTERNALIP/manila 

# update DEFAULT stanza in manila.conf with information about other OpenStack Services
# - covers the services username/password and url.
# - set up hooks to nova, cinder, and neutron
#   using keystone internal VIP.
KEYSTONE_INTERNALIP=$(openstack endpoint show keystone | awk '/ internalurl /' | grep -Eo '(http|https)://{1}\S+')
MYNOVA_PASSWORD=( $(grep -v '^#' /etc/nova/nova.conf | grep connection | awk -F[:@] '{print $3}') )
openstack-config --set /etc/manila/manila.conf DEFAULT nova_admin_auth_url $KEYSTONE_INTERNALIP 
openstack-config --set /etc/manila/manila.conf DEFAULT nova_admin_tenant_name service 
openstack-config --set /etc/manila/manila.conf DEFAULT nova_admin_username nova 
openstack-config --set /etc/manila/manila.conf DEFAULT nova_admin_password $MYNOVA_PASSWORD

MYCINDER_PASSWORD=( $(grep -v '^#' /etc/cinder/cinder.conf | grep connection | awk -F[:@] '{print $3}') )
openstack-config --set /etc/manila/manila.conf DEFAULT cinder_admin_auth_url $KEYSTONE_INTERNALIP 
openstack-config --set /etc/manila/manila.conf DEFAULT cinder_admin_tenant_name service 
openstack-config --set /etc/manila/manila.conf DEFAULT cinder_admin_username cinder 
openstack-config --set /etc/manila/manila.conf DEFAULT cinder_admin_password $MYCINDER_PASSWORD 

NEUTRON_INTERNALIP=$(openstack endpoint show neutron | awk '/ internalurl /' | grep -Eo '(http|https)://{1}\S+')
MYNEUTRON_PASSWORD=( $(grep -v '^#' /etc/neutron/neutron.conf | grep connection | awk -F[:@] '{print $3}') )
openstack-config --set /etc/manila/manila.conf DEFAULT neutron_admin_auth_url $KEYSTONE_INTERNALIP 
openstack-config --set /etc/manila/manila.conf DEFAULT neutron_url $NEUTRON_INTERNALIP 
openstack-config --set /etc/manila/manila.conf DEFAULT neutron_admin_tenant_name service 
openstack-config --set /etc/manila/manila.conf DEFAULT neutron_admin_username neutron 
openstack-config --set /etc/manila/manila.conf DEFAULT neutron_admin_password $MYNEUTRON_PASSWORD 
openstack-config --set /etc/manila/manila.conf DEFAULT neutron_api_insecure false 
openstack-config --set /etc/manila/manila.conf DEFAULT neutron_auth_strategy keystone 
openstack-config --set /etc/manila/manila.conf DEFAULT neutron_url_timeout 30

# update keystone_authtoken stanza in manila.conf
# - covers the manila service account created earlier
# - necessary or manila will use 127.0.0.1:35357 for auth and is
#   undesired in HA environment, and this is annoying due to:
#   (python-manilaclient release < 1.5.0(Liberty) still uses Keystone Auth Version 2)
KEYSTONE_ADMINIP=( $(grep -v '^#' /etc/cinder/cinder.conf | grep identity_uri | awk -F[=] '{print $2}') )
openstack-config --set /etc/manila/manila.conf keystone_authtoken auth_uri $KEYSTONE_INTERNALIP
openstack-config --set /etc/manila/manila.conf keystone_authtoken identity_uri $KEYSTONE_ADMINIP
openstack-config --set /etc/manila/manila.conf keystone_authtoken admin_tenant_name service
openstack-config --set /etc/manila/manila.conf keystone_authtoken admin_user manila
openstack-config --set /etc/manila/manila.conf keystone_authtoken admin_password $MANILA_USER_PASSWORD

# create [netapp] stanzy in manila.conf and take advantage of NetApp Manila
# Remember to modify the following to suit your environment
# - netapp_server_hostname: the control path
# - netapp_password: you know this
# - driver_handes_share_servers: false for this reference architecture
# - netapp_vserver, storage_family, etc.
# - transport type and server port (you should be secure).
openstack-config --set /etc/manila/manila.conf netapp share_driver manila.share.drivers.netapp.common.NetAppDriver
openstack-config --set /etc/manila/manila.conf netapp netapp_storage_family ontap_cluster
openstack-config --set /etc/manila/manila.conf netapp share_backend_name netapp
openstack-config --set /etc/manila/manila.conf netapp netapp_server_hostname $NETAPP_CLUSTERADMIN_LIF
openstack-config --set /etc/manila/manila.conf netapp netapp_login $NETAPP_CLUSTERADMIN_USER
openstack-config --set /etc/manila/manila.conf netapp netapp_password $NETAPP_CLUSTERADMIN_PASS
openstack-config --set /etc/manila/manila.conf netapp netapp_vserver $NETAPP_MANILA_SVM
openstack-config --set /etc/manila/manila.conf netapp netapp_transport_type https 
openstack-config --set /etc/manila/manila.conf netapp netapp_server_port 443 
openstack-config --set /etc/manila/manila.conf netapp driver_handles_share_servers false 
openstack-config --set /etc/manila/manila.conf netapp netapp_volume_name_template 'share_%(share_id)s' 
openstack-config --set /etc/manila/manila.conf netapp netapp_vserver_name_template 'os_%s' 
openstack-config --set /etc/manila/manila.conf netapp netapp_aggregate_name_search_pattern '(.*)'
openstack-config --set /etc/manila/manila.conf netapp netapp_lif_name_template 'os_%(net_allocation_id)s'
openstack-config --set /etc/manila/manila.conf netapp netapp_port_name_search_pattern '(.*)'

# fix file permissions and ownership so SElinux is happy
chmod 640 /etc/manila/manila.conf
chgrp manila /etc/manila/manila.conf

# restart HAProxy services so that manila specific
# provisions are picked up and started.
# reload doesn't work here unfortunately, i tried.
systemctl restart haproxy.service
