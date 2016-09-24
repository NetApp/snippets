# ONTAP Data Access Management Using PowerShell

These scripts were developed for the Insight 2016 session 61718.  They create the framework for a simple to consume storage catalog, where the user is only asked the most basic of information and the system handles the work for them.

## Performance Capacity

Performance capacity, which is available in ONTAP 9, plays a significant role during the volume creation process.  The user is only asked what type of storage they want: Flash, Hybrid, or Disk.  The script then gathers those aggregate types and queries the performance capacity to determine which one is the best candidate for provisioning.

## Scripts

At a high level, the user should only care about a few things...

1) How much capacity do I need?
2) What performance do I need (Flash, Hybrid, Disk)?
3) How do I access my capacity (export, share, LUN)?

We can enable some extra functions that are beneficial to the overall functionality of the storage catalog as well:

* Volume snapshot/revert
* Clone from snapshot

And, of course, we need to manage access to the export/share/LUN, so those functions are necessary as well.

***Pre-requisites:***

* The scripts all assume that an existing connection to a cluster has been made.  They do not prompt for credentials nor load the DataONTAP module.  
* The assumption is that an SVM = a tenant.  They *will* be able to see all of the volumes associated with the SVM.  
* The SVM must have access to aggregates for each disk type or provisioning will fail when the missing type is requested.
* The SVM must have LIFs for each protocol already in place.  If more than one exists for the protocol, they will be randomly assigned, with favor to the node which owns the volume.

### volume.ps1

```powershell
# list volumes in the SVM
.\volume.ps1 -Vserver CXE -List

# create a volume
.\volume.ps1 -Vserver CXE -Create -Name ACS -Capacity 10 -Type hybrid

# resize a volume
.\volume.ps1 -Vserver CXE -Modify -Name ACS -Capacity 20

# hide the snap dir, this is useful for some apps...like MySQL/MariaDB
.\volume.ps1 -Vserver CXE -Modify -Name ACS -ShowSnapDir:$false

# create a clone from a snapshot
.\volume.ps1 -Vserver CXE -Clone -Name ACS_Clone -SourceVolume ACS -SourceSnapshot testme

# destroy a volume, note this will fail if a locked snap exists, or there is a LUN/share/export
.\volume.ps1 -Vserver CXE -Name ACS -Destroy
```

### snapshot.ps1

```powershell
# list snapshots for a volume
.\snapshot.ps1 -Vserver CXE -Volume ACS -List

# create a snapshot
.\snapshot.ps1 -Vserver CXE -Volume ACS -Create -Snapshot testme

# destroy a snapshot
.\snapshot.ps1 -Vserver CXE -Volume ACS -Destroy -Snapshot testme

# revert to a snapshot - usual warnings apply...meaning, it won't warn
.\snapshot.ps1 -Vserver CXE -Volume ACS -Revert -Snapshot testme
```

### export.ps1

When "creating" an export, we are junctioning the volume and creating an export policy.  It has no rules, thus no access, until the AddAccess is called.  Destroying access removes the export policy and unjunctions the volume.

```powershell
# get the status of the export...enabled or disabled
.\export.ps1 -Vserver CXE -Volume ACS -Status

# create the export
.\export.ps1 -Vserver CXE -Volume ACS -Create

# add access
.\export.ps1 -Vserver CXE -Volume ACS -AddAccess "0.0.0.0/0"

# list access rules
.\export.ps1 -Vserver CXE -Volume ACS -ListAccess

# remove access
.\export.ps1 -Vserver CXE -Volume ACS -RemoveAccess "0.0.0.0/0"

# remove the export
.\export.ps1 -Vserver CXE -Volume ACS -Destroy
```
