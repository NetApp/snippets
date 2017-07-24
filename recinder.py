#!/usr/bin/python
import subprocess

#
# This code snippet will assist in detatching and re-attaching cinder block devices in order
# from nova instances.  This is a special case script, it will only detach and reattach
# block devices other than the root devices.
#
# Copyright 2017 NetApp, Inc.
#
# This type os script must be called as a sourced user associated with a project.
# It will only detach/reattach devices belonging to that user.
#
# Steps:
# 1) Form  a hash mapping all block devices associated with all nova instances owned by the present user
# 2) Order the cinder volumes per instance, such as sdb then sdc then sde ...
# 3) Detach all of the block devices (other than sda) in order
# 4) Reattach all block devices in the same order: sdb, sdc, sdd...
#

def get_current_mapping():
    p = subprocess.Popen(['openstack','volume','list','-f','csv'], stdout=subprocess.PIPE)
    a = p.communicate()[0]
    
    instance_to_block_hash = {}
    for line in a.split('\n'):
         if 'Attached to' in line and '/dev/vda ' not in line:
             if '/dev/' in line:
                 volume_id,volume_name,state,size,attached_to = line.split(',')
                 attachment = attached_to.split('"')[1].strip().split(' ')
                 instance = attachment[2]
                 device = attachment[4]
                 if instance in instance_to_block_hash:
                     instance_to_block_hash[instance].append({device:volume_id})
                 else:
                     instance_to_block_hash[instance] = [{device:volume_id}]
    return instance_to_block_hash

def block_device_action(direction=None,instance_to_block_hash=None):
    for instance in instance_to_block_hash.keys():
        for device in sorted(instance_to_block_hash[instance]):
            volume_id = device.values()[0][1:-1]
            device_name =  device.keys()[0]
            print('openstack server %s volume %s %s' % (direction,instance,volume_id))
            subprocess.call(['openstack','server',direction,'volume',instance,volume_id])

instance_to_block_hash = get_current_mapping()
block_device_action(direction='remove',instance_to_block_hash=instance_to_block_hash)
block_device_action(direction='add',instance_to_block_hash=instance_to_block_hash)
