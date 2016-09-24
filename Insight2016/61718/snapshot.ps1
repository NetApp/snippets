<#
 # Copyright 2016 NetApp, Inc.

snapshot.ps1

Create, revert, and delete snapshots for a volume

#>

Param(
    # the SVM which we're dealing with
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='List')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Create')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Destroy')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Revert')]
    [String]$Vserver
    ,
    
    # the name of the volume which will have snapshot actions
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='List')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Create')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Destroy')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Revert')]
    [String]$Volume
    ,

    # list the snapshots for a volume
    [parameter(Mandatory=$false, ValueFromPipeline=$true, ParameterSetName='List')]
    [Switch]$List
    ,

    # the name of the snapshot
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Create')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Destroy')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Revert')]
    [Alias('Name')]
    [String]$Snapshot
    ,

    [parameter(Mandatory=$false, ParameterSetName='Create')]
    [Switch]$Create
    ,

    [parameter(Mandatory=$false, ParameterSetName='Destroy')]
    [Switch]$Destroy
    ,

    [parameter(Mandatory=$false, ParameterSetName='Revert')]
    [Switch]$Revert
)

Begin {
    function List {
        Param(
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,
            [DataONTAP.C.Types.Volume.VolumeAttributes]$Volume
        )

        Write-Verbose "Starting snapshot list"
        Write-Verbose "  Volume: $($Volume.Name)"

        $result = $Volume | Get-NcSnapshot | Select Name,Created

        Write-Verbose "  Snapshots found: $($result | Out-String)"

        $result
    }

    function Create {
        Param(
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,
            [DataONTAP.C.Types.Volume.VolumeAttributes]$Volume,
            [String]$Snapshot
        )

        Write-Verbose "Starting snapshot create"
        Write-Verbose "  Volume: $($Volume.Name); Snapshot: $($Snapshot)"

        # create the snapshot
        $result = $Volume | New-NcSnapshot -Snapshot $Snapshot -ErrorAction Stop

        Write-Verbose "  Snapshot created: $($result | Out-String)"

        # return the result
        #$result | Select Name,Created
        $true

    }

    function Destroy {
        Param(
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,
            [DataONTAP.C.Types.Volume.VolumeAttributes]$Volume,
            [DataONTAP.C.Types.Snapshot.SnapshotInfo]$Snapshot
        )

        Write-Verbose "Starting snapshot destroy"
        Write-Verbose "  Volume: $($Volume.Name); Snapshot: $($Snapshot.Name)"

        $result = $Snapshot | Remove-NcSnapshot -Confirm:$false -ErrorAction Stop

        Write-Verbose "  Snapshot removed"

        # the remove operation will throw an error, so if we're here, it succeeded
        $true

    }

    function Revert {
        Param(
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,
            [DataONTAP.C.Types.Volume.VolumeAttributes]$Volume,
            [DataONTAP.C.Types.Snapshot.SnapshotInfo]$Snapshot
        )

        Write-Verbose "Starting snapshot revert"
        Write-Verbose "  Volume: $($Volume.Name); Snapshot: $($Snapshot.Name)"

        $result = Restore-NcSnapshotVolume -VserverContext $Svm -Volume $Volume -SnapName $Snapshot -Confirm:$false -ErrorAction Stop

        # the above outputs a volume object, but we don't care about it.  so long
        # as it didn't fail, return
        $true
    }

}

Process {
    # make sure we're connected to a controller
    if ($global:CurrentNcController -eq $null) {
        throw "No connection to an ONTAP system was found"
    }

    # make sure the SVM is valid
    $svm = Get-NcVserver -Name $Vserver

    if ($Svm -eq $null) {
        throw "SVM not found"
    }

    # make sure the volume is valid
    $vol = $Svm | Get-NcVol -Name $Volume

    if ($vol -eq $null) {
        throw "Volume not found"
    }

    switch ($PsCmdlet.ParameterSetName) {
        "List" {
            $output = [array](List -Svm $svm -Volume $vol)
        }

        "Create" {
            $output = Create -Svm $svm -Volume $vol -Snapshot $Snapshot
        }

        "Destroy" {
            # make sure the snapshot exists
            $snap = $vol | Get-NcSnapshot -SnapName $Snapshot

            if ($snap -eq $null) {
                throw "Snapshot not found"
            }

            $output = Destroy -Svm $svm -Volume $vol -Snapshot $snap
        }

        "Revert" {
            # make sure the snapshot exists
            $snap = $vol | Get-NcSnapshot -SnapName $Snapshot

            if ($snap -eq $null) {
                throw "Snapshot not found"
            }

            $output = Revert -Svm $svm -Volume $vol -Snapshot $snap
        }
    }

    # send the output...out
    ConvertTo-Json $output -Depth 2 -Compress

}