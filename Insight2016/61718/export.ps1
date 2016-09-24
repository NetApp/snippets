<#
 # Copyright 2016 NetApp, Inc.


export.ps1

Create, manage, destroy NFS exports for a volume, as well as export rules

#>

Param(
    # the SVM which we're dealing with
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='List')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Info')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Status')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Create')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Destroy')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='AddAccess')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='RemoveAccess')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='ListAccess')]
    [String]$Vserver
    ,
    
    # the name of the volume which will have snapshot actions
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Info')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Status')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Create')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Destroy')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='AddAccess')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='RemoveAccess')]
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='ListAccess')]
    [String]$Volume
    ,

    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='List')]
    [Switch]$List
    ,

    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Info')]
    [Switch]$Info
    ,

    # show whether the export is enabled/disabled
    [parameter(Mandatory=$false, ValueFromPipeline=$true, ParameterSetName='Status')]
    [Switch]$Status
    ,

    # create an export
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Create')]
    [Switch]$Create
    ,

    # remove the export
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Destroy')]
    [Switch]$Destroy
    ,

    # add an access rule
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='AddAccess')]
    [String]$AddAccess
    ,

    # remove an access rule
    [parameter(Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='RemoveAccess')]
    [String]$RemoveAccess
    ,

    # list the access rules for an export policy (which is the same name as the volume)
    [parameter(Mandatory=$false, ValueFromPipeline=$true, ParameterSetName='ListAccess')]
    [Switch]$ListAccess
)

Begin {
    function List {
        Param(
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm
        )

        # exports which were created by us will have an export policy
        # with the same name as the volume
        $exports = @()

        $Svm | Get-NcExportPolicy -Attributes @{} | %{
            if (( Get-NcVol -Query @{ Name=$_.PolicyName } -Attributes @{} ) -ne $null) {
                $exports += [String]$_.PolicyName
            }
        }

        [String[]]$exports
    }

    function Info {
        Param(
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,
            [DataONTAP.C.Types.Volume.VolumeAttributes]$Volume
        )

        # start by getting the volume info
        $info = .\volume.ps1 -Info -Vserver $Svm.Vserver -Name $Volume.Name | ConvertFrom-Json
        

        # we have to reverse engineer the LIF which we want to use
        # volume -> aggregate -> node, then SVM -> LIF -> node
        # we then pick a LIF which is on that node and supports the protocol
        
        # get the node which is hosting the volume for this export
        $node = (Get-NcAggr $Volume.Aggregate).Nodes[0]

        # get the nfs lifs for this SVM
        $lifs = $Svm | Get-NcNetInterface -Query @{ DataProtocols="nfs" }

        # capture the LIF for the node which hosts the volume, if one exists
        $homeLif = $lifs | ?{ $_.HomeNode -eq $node } | Select-Object -First 1

        if ($homeLif -ne $null) {
            # there is a home lif
            $connectAt = ($homeLif).Address
        } else {
            # no home lif, just use any lif
            $connectAt = ($lifs | Get-Random).Address
        }

        $info | Add-Member -MemberType NoteProperty -Name ConnectAt -Value "$($connectAt):$($Volume.JunctionPath)"

        $info

    }

    function Status {
        Param(
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,
            [DataONTAP.C.Types.Volume.VolumeAttributes]$Volume
        )

        $policy = $Svm | Get-NcExportPolicy -PolicyName $vol.Name

        if ($policy -eq $null) {
            # no policy, status = disabled
            $false
        } else {
            # policy, status = enabled
            $true
        }

    }

    function Create {
        Param(
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,
            [DataONTAP.C.Types.Volume.VolumeAttributes]$Volume
        )

        # ensure the volume is junctioned
        if ($Volume.JunctionPath -eq $null) {
            $mount = $Volume | Mount-NcVol -JunctionPath "/$($Volume.Name)" -ErrorAction Stop
        }

        # create the export policy 
        $policy = $Svm | New-NcExportPolicy -Name $Volume.Name -ErrorAction Stop
        
        # if we didn't error, then it succeeded
        $true
    }

    function Destroy {
        Param(
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,
            [DataONTAP.C.Types.Volume.VolumeAttributes]$Volume
        )

        # remove the export policy
        $policy = $Svm | Get-NcExportPolicy $Volume.Name
        
        if ($policy -ne $null) {
            $remove = $policy | Remove-NcExportPolicy -Confirm:$false -ErrorAction Stop
        }

        # unjunction the volume
        $unjunction = $Volume | Dismount-NcVol -ErrorAction SilentlyContinue

        # if we didn't get an error, it succeeded
        $true
    }

    function AddAccess {
        Param(
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,
            [DataONTAP.C.Types.Volume.VolumeAttributes]$Volume,
            [DataONTAP.C.Types.Exports.ExportPolicyInfo]$Policy,
            [String]$Rule
        )

        # create an export policy rule for NFS access
        $splat = @{
            # enable all nfs versions
            "Protocol" = "nfs";

            # the user provided rule
            "ClientMatch" = $Rule;

            # don't manage security here
            "ReadOnlySecurityFlavor" = "any";
            "ReadWriteSecurityFlavor" = "any";
            "SuperUserSecurityFlavor" = "any";
        }
 
       $result = $Policy | New-NcExportRule @splat -ErrorAction Stop

       $true
    }

    function RemoveAccess {
        Param(
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,
            [DataONTAP.C.Types.Volume.VolumeAttributes]$Volume,
            [DataONTAP.C.Types.Exports.ExportPolicyInfo]$Policy,
            [DataONTAP.C.Types.Exports.ExportRuleInfo]$Rule
        )

        $result = $Policy | Remove-NcExportRule -Index $Rule.RuleIndex -Confirm:$false -ErrorAction Stop

        $true
    }

    function ListAccess {
        Param(
            [DataONTAP.C.Types.Vserver.VserverInfo]$Svm,
            [DataONTAP.C.Types.Volume.VolumeAttributes]$Volume
        )

        # get the rules associated with the vol's export policy
        $result = [String[]](($Svm | Get-NcExportPolicy -Name $Volume.Name | Get-NcExportRule).ClientMatch)
        
        $result
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

    if ($Volume -eq $null) {
        throw "Volume not found"
    }

    switch ($PsCmdlet.ParameterSetName) {
        "List" {
            $output = [String[]](List -Svm $svm)
        }

        "Info" {
            $output = Info -Svm $svm -Volume $vol
        }

        "Status" {
            $output = Status -Svm $svm -Volume $vol
        }

        "ListAccess" {
            $output = [String[]](ListAccess -Svm $svm -Volume $vol)
        }

        "Create" {
            $output = Create -Svm $svm -Volume $vol
        }

        "Destroy" {
            $output = Destroy -Svm $svm -Volume $vol
        }

        "AddAccess" {
            # validate the policy
            $policy = $Svm | Get-NcExportPolicy $vol.Name

            if ($policy -eq $null) {
                throw "Cannot find export policy for volume"
            }

            $output = AddAccess -Svm $svm -Volume $vol -Policy $policy -Rule $AddAccess

        }

        "RemoveAccess" {
            # validate the policy
            $policy = $Svm | Get-NcExportPolicy -PolicyName $vol.Name

            if ($policy -eq $null) {
                throw "Cannot find export policy for volume."
            }

            # validate the rule
            $rule = Get-NcExportRule -Query @{ PolicyName=$policy.PolicyName; ClientMatch=$RemoveAccess }

            if ($rule -eq $null) {
                throw "Cannot find export rule in policy."
            }

            $output = RemoveAccess -Svm $svm -Volume $vol -Policy $policy -Rule $rule
        }
    }

    ConvertTo-Json $output -Depth 2 -Compress
}