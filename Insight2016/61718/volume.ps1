<#
 # Copyright 2016 NetApp, Inc.

volume.ps1

Create and manage volumes

#>

[CmdletBinding(SupportsShouldProcess=$true)]

Param(
    # mandatory for all parameter sets, the SVM which to create the volume
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Info')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='List')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Create')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Modify')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Clone')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Destroy')]
    [String]$Vserver
    ,

    # list the volumes for an SVM
    [parameter(Mandatory=$false, ValueFromPipeline=$true, ParameterSetName='List')]
    [Switch]$List
    ,

    # mandatory for all parameter sets, the volume name which we're operating on
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Info')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Create')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Modify')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Clone')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Destroy')]
    [String]$Name
    ,

    [parameter(Mandatory=$false, ParameterSetName='Info')]
    [Switch]$Info
    ,

    # volume creation options: Capacity, Type
    [parameter(Mandatory=$false, ParameterSetName='Create')]
    [Switch]$Create
    ,

    # options: Capacity, ShowSnapDir
    [parameter(Mandatory=$false, ParameterSetName='Modify')]
    [Switch]$Modify
    ,

    # options: SourceVolume, SourceSnapshot
    [parameter(Mandatory=$false, ParameterSetName='Clone')]
    [Switch]$Clone
    ,

    # options: none
    [parameter(Mandatory=$false, ParameterSetName='Destroy')]
    [Switch]$Destroy
    ,

    # the capacity for new or modified volumes
    [parameter(Mandatory=$true, ParameterSetName='Create')]
    [parameter(Mandatory=$false, ParameterSetName='Modify')]
    [Int]$Capacity
    ,

    # enable/disable the snapshot directory
    [parameter(Mandatory=$false, ParameterSetName='Modify')]
    [Switch]$ShowSnapDir
    ,

    # the type of storage to create the volume on
    [parameter(Mandatory=$true, ParameterSetName='Create')]
    [ValidateSet('ssd', 'hybrid', 'hdd')]
    [String]$Type
    ,

    # the source volume for a clone
    [parameter(Mandatory=$true, ParameterSetName='Clone')]
    [String]$SourceVolume
    ,

    # the source snapshot of the source volume for a clone
    [parameter(Mandatory=$true, ParameterSetName='Clone')]
    [String]$SourceSnapshot
    
)

Begin {
    function Info {
        Param(
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,
            [String]$Name
        )

        # this is meant to homogenize the output for all volumes into a few basic pieces of information:
        # 1) the name
        # 2) total size
        # 3) avaialble size
        # 4) how to mount/connect
        # 5) the storage type

        $output = "" | Select Name,TotalSize,Available,Type

        $attributes = @{
            VolumeIdAttributes = @{ };
            VolumeSpaceAttributes = @{ };
            VolumeStateAttributes = @{ };
        }

        $volume = Get-NcVol $Name -Attributes $attributes

        $output.Name = $volume.Name
        $output.TotalSize = $volume.TotalSize
        $output.Available = $volume.VolumeSpaceAttributes.SizeAvailable
        $output.Type = (Get-NcAggr $volume.Aggregate -Attributes @{ AggrRaidAttributes = @{ } }).AggrRaidAttributes.AggregateType
        
        $output
    }

    function List {
        Param(
            # the SVM
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm
        )

        Write-Verbose "Starting volume list"
        Write-Verbose "  Svm = $($Svm.Vserver)"

        $Svm | Get-NcVol | %{ Info -Svm $Svm -Name $_.Name }
    }

    function Create {
        Param(
            # the SVM
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,

            # a name for the volume
            [String]$Name,
            
            # capacity in GB
            [Int]$Capacity,

            # the storage types available
            [ValidateSet('ssd', 'hybrid', 'hdd')]
            [String]$Type
        )

        Write-Verbose "Starting volume create"
        Write-Verbose "  Svm = $($Svm.Vserver); Name = $($Name); Capacity = $($Capacity); Type = $($Type);"

        # check to see if the volume already exists
        $check = $Svm | Get-NcVol -Name $Name

        if ($check -ne $null) {
            throw "Volume already exists"
        }

        #
        # determine the best place to provision the volume
        #

        # can't use an aggr the SVM can't access or of the wrong type
        $aggrQuery = @{
            Name = "$($Svm.AggrList -join '|')";
            
            AggrRaidAttributes = @{
                AggregateType = $Type;
            }
        }

        $potentialAggrs = Get-NcAggr -Query $aggrQuery -Attributes @{ AggrSpaceAttributes=@{}; AggrOwnershipAttributes=@{} }

        # an eligible aggr must also have (volSize * .4) + (aggrSize * .1) free space
        # in other words, we want to have 10% free space remaning in the aggregate after
        # we allocate %40 of the volume space...we're assuming the storage user will only
        # use 40% of their allocated capacity, which gives us a 2.5:1 overcommit ratio
        $eligibleAggrs = $potentialAggrs | Where-Object { 
                $_.AggrSpaceAttributes.SizeAvailable -gt ((($Capacity * 1gb) * .4) + ($_.AggrSpaceAttributes.SizeTotal * .1))
            }
        

        if ($eligibleAggrs -eq $null) {
            throw "No aggregates available with disk type $($Type) and required free space"
        }

        #
        # for ssd/AFF, we want to choose the controller with the most perf capacity remaning based
        # on CPU, not the aggregate...the assumption is that the controller will run out of capacity
        # to serve IOPS before the disks do.  for hdd/hybrid, use the aggregate utilization
        #

        if ($Type -eq "ssd") {
            # get all the eligible nodes
            $nodes = ($eligibleAggrs).AggrOwnershipAttributes.HomeName | Sort-Object | Get-Unique

            # get the node with the most weekly perf capacity remaining
            $node = ($nodes | Get-NcNodePerfCapacity -Weekly | Sort-Object -Property UtilCapRemain -Descending | Select-Object -First 1).Name

            # get the aggregate on the node with the most GB capacity remaining
            $aggr = ($eligibleAggrs | ?{ $_.aggrownershipattributes.homename -eq $node } | Sort-Object -Property Available -Descending | Select-Object -First 1).Name

        } else {
            # get the aggr with the most weekly perf capacity remaining, don't care about node
            $aggr = ($eligibleAggrs | Get-NcAggrPerfCapacity -Weekly | Sort-Object -Property UtilCapRemain -Descending | Select-Object -First 1).Name

        }

        Write-Verbose "  Selected aggregate: $($aggr)"
        Write-Verbose "  Eligible aggregates perf capacity: $($eligibleAggrs | Get-NcAggrPerfCapacity -Weekly | ft -AutoSize | Out-String)"

        #
        # create the volume
        #
        $splat = @{
            # user specified name
            'Name' = $Name;

            # as determined by performance capacity
            'Aggregate' = $aggr;

            # how to access
            'JunctionPath' = "/$($Name)";
            
            # default to unix, change during share creation if needed
            'SecurityStyle' = 'unix';

            # default snapshot policy to none...let the user control them
            'SnapshotPolicy' = 'none';

            # always thin provision
            'SpaceReserve' = 'none';

            # no snapreserve
            'SnapshotReserve' = '0';

            # size of the volume, in GB
            'Size' = "$($Capacity)g"
        }

        Write-Verbose "  Volume create options: $($splat | Out-String)"

        $volume = $Svm | New-NcVol @splat -ErrorAction Stop

        #
        # enable options based on storage type
        #
        
        # all - post-process dedupe with schedule = auto and compaction
        $sis = $volume | Enable-NcSis -ErrorAction Stop > $null
        
        try {
            $sis = $volume | Set-NcSis -Schedule "auto" -EnableDataCompaction:$true -ErrorAction Stop
        } catch {
            # ignore the error if compaction is already enabled
            if ($_.Exception -match "Compaction is already enabled") {
                # do nothing
            } else {
                throw $_
            }
        }

        Write-Verbose "  Deduplication and compaction enabled"

        if ($Type -eq "Flash") {
            # AFF - inline deduplication and compression
            $sis = $volume | Set-NcSis -EnableInlineDedupe:$true -InlineCompression:$true -ErrorAction Stop

            Write-Verbose "  AFF volume - inline dedupe and compression enabled"
        }

        #
        # enable autogrow/autoshrink
        #

        $splat = @{
            'Mode' = 'grow_shrink';
            'MinimumSize' = "$($Capacity)g";
            'MaximumSize' = "$([Math]::Ceiling($Capacity * 1.25))g"
        }

        $autosize = $volume | Set-NcVolAutosize @splat -ErrorAction Stop > $null
        $autosize = $volume | Set-NcVolAutosize -Enabled -ErrorAction Stop > $null

        # sane (?) defaults
        $autosize = $volume | Set-NcVolAutosize -GrowThresholdPercent 98 -ShrinkThresholdPercent 90 -ErrorAction Stop

        #Write-Verbose "  Auto grow/shrink set: $($splat | Out-String)"

        #
        # Create a QoS policy with no limit
        #
        try {
            $policy = $Svm | New-NcQosPolicyGroup -Name $Name -MaxThroughput INF -ErrorAction Stop
        } catch {
            # ignore duplicate entry QoS policies
            if ($_.CategoryInfo.Reason -eq "EDUPLICATEENTRY") {
                # do nothing
            } else {
                throw $_
            }
        }

        $update = Update-NcVol -Query @{ Vserver=$Svm.Vserver; Name=$Name } -Attributes @{ VolumeQoSAttributes=@{ PolicyGroupName=$Name } } -ErrorAction Stop

        Write-Verbose "  QoS policy $($Name) created and assigned"

        #
        # return the volume object
        #

        $attributes = @{
            VolumeIdAttributes = @{ };
            VolumeSpaceAttributes = @{ };
            VolumeStateAttributes = @{ };
        }

        Info -Svm $Svm -Name $volume.Name
    }

    function Modify {
        Param(
            # the SVM
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,

            # a name for the volume
            [String]$Name,
            
            # capacity in GB
            [Int]$Capacity,

            # whether to show the snap directory
            [String]$ShowSnapDir
        )

        Write-Verbose "Starting volume modify"
        Write-Verbose "  Svm: $($Svm.Vserver); Name: $($Name); Capacity: $($Capacity); ShowSnapDir: $($ShowSnapDir)"

        $volume = $Svm | Get-NcVol -Name $Name

        if ($volume -eq $null) {
            throw "Volume not found."
        }

        # was capacity provided?
        if ($Capacity -ne 0) {
            Write-Verbose "  Changing volume size from $($volume.size / 1gb) to $($Capacity)"

            $size = $volume | Set-NcVolSize -NewSize "$($Capacity)g" -ErrorAction Stop
        }

        # was showsnapdir provided?
        if ($ShowSnapDir -eq "True") {
            Write-Verbose "  Showing snapshot directory"
            $snapDir = $volume | Set-NcVolOption -Key nosnapdir -Value off -ErrorAction Stop

        } elseif ($ShowSnapDir -eq "False") {
            Write-Verbose "  Hiding snapshot directory"
            $snapDir = $volume | Set-NcVolOption -Key nosnapdir -Value on -ErrorAction Stop

        }
        
        # send back an updated info object
        Info -Svm $Svm -Name $Name

    }

    function Clone {
        Param(
             # the SVM
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,

            # a name for the volume
            [String]$Name,

            # the source volume name
            [String]$SourceVolume,

            # the source snapshot name
            [String]$SourceSnapshot
        )

        Write-Verbose "Starting volume clone"
        Write-Verbose "  Svm: $($Svm.Vserver); Name: $($Name); SourceVolume: $($SourceVolume); SourceSnapshot: $($SourceSnapshot)"

        $sVolume = Get-NcVol -Name $SourceVolume

        if ($sVolume -eq $null) {
            throw "Source volume not found."
        }

        # create a new QoS policy for the volume
        $qos = $Svm | New-NcQosPolicyGroup -Name $Name -MaxThroughput INF -ErrorAction Stop

        Write-Verbose "  New QoS policy $($Name) created"

        $splat = @{
            # the svm
            'Vserver' = $Svm.Vserver;

            # the new name
            'CloneVolume' = $Name;

            # the source volume
            'ParentVolume' = $SourceVolume;

            # the source snapshot
            'ParentSnapshot' = $SourceSnapshot;

            # junction path
            'JunctionPath' = "$($Name)";

            # make sure it's active
            'JunctionActive' = $true;

            # the qos policy
            'QosPolicyGroup' = $Name;
        }

        Write-Verbose "  Clone parameters: $($splat | Out-String)"

        $volume = New-NcVolClone @splat -ErrorAction Stop

        #$volume

        Info -Svm $Svm -Name $Name
    }

    function Destroy {
        Param(
            # the SVM
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,

            # a name for the volume
            [String]$Name
        )

        $volume = $Svm | Get-NcVol -Name $Name -ErrorAction Stop

        if ($volume -eq $null) {
            throw "Volume not found"
        }

        #
        # these should all be done before we get here
        #
        
        # check for LUNs
        if ((Get-NcLun -Volume $volume).count -gt 0) {
            throw "Cannot delete volume, LUNs are present."
        }

        # check for shares
        if (($volume | Get-NcCifsShare).count -gt 0) {
            throw "Cannot delete volume, shares are present."
        }

        # check for junction
        if ($volume.JunctionPath -ne $null ) {
            throw "Cannot delete volume, still junctioned."
        }

        # 
        # check to see if the volume has a busy snapshot. if so, it's
        # a flexclone source, so we can't destroy it
        #
        if (($volume | Get-NcSnapshot | ?{ $_.Dependency -ne $null }).count -gt 0) {
            throw "Cannot delete volume, locked snapshots exist"
        }

        # offline the volume
        $offline = $volume | Set-NcVol -Offline -ErrorAction Stop

        # destroy it
        $destroy = $volume | Remove-NcVol -Confirm:$false -ErrorAction Stop

        # remove the QoS policy
        try {
            Remove-NcQosPolicyGroup -Name $Name -ErrorAction Stop
        } catch {
            # ignore the error if the QoS policy isn't found
            if ($_.CategoryInfo.Reason -eq "EOBJECTNOTFOUND") {
                # do nothing
            } else {
                throw $_
            }
        }

    }

    # add the custom headroom module
    Import-Module Headroom -Verbose:$false
}

Process {
    # make sure we're connected to a controller
    if ($global:CurrentNcController -eq $null) {
        throw "No connection to an ONTAP system was found"
    }

    $Svm = Get-NcVserver $Vserver

    if ($Svm -eq $null) {
        throw "Vserver was not found"
    }

    switch ($PsCmdlet.ParameterSetName) {
        "Info" {
            $output = Info -Svm $Svm -Name $Name
        }

        "List" {
            # get the VM list, return json
            $output = [array](List -Svm $Svm)
        }

        "Create" {
            # create the volume, this returns an info object
            $output = Create -Svm $Svm -Name $Name -Capacity $Capacity -Type $Type
        }

        "Modify" {
            if ($Capacity -eq $null -and $ShowSnapDir -eq $null) {
                throw "One or more of Capacity or ShowSnapDir are required when modifying a volume"
            }

            # build the params
            $splat = @{
                'Svm' = $Svm;
                'Name' = $Name;
                'Capacity' = $null;
                'ShowSnapDir' = $null;
            }

            # set optional parameters
            if ($Capacity -ne $null) {
                $splat.Capacity = $Capacity
            }

            if ($ShowSnapDir.IsPresent -eq $true) {
                $splat.ShowSnapDir = $ShowSnapDir
            }

            # this returns an info object
            $output = Modify @splat
        }

        "Clone" {
            # output a new volume from the source
            $output = Clone -Svm $Svm -Name $Name -SourceVolume $SourceVolume -SourceSnapshot $SourceSnapshot
        }

        "Destroy" {
            # destroy the volume
            Destroy -Svm $Svm -Name $Name

            # if the above returns without error, then the remove
            # was successful
            $output = $true
        }
    }

    Write-Verbose "Script output: $($output | Out-String)"

    # output json for vRO
    ConvertTo-Json $output -Depth 2 -Compress

}