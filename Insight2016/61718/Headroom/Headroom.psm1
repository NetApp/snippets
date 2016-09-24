#Requires –Modules DataONTAP
# load types
. $psScriptRoot\Headroom.Type.ps1
# Load module global variables from manifest
# $LogPath =  $ExecutionContext.SessionState.Module.PrivateData["LogPath"]

<#
.Synopsis
   Retrieve the Node Performance Capacity information a.k.a. Headroom.
.DESCRIPTION
   Retrieve the Node Performance Capacity information a.k.a. Headroom.
.EXAMPLE
   .\Get-NcAggrPerfCapacity.ps1 

Name          : VICE-07
Utilization   : 2
UtilCapRemain : 65
Latency       : 309
LatCapRemain  : 516
Ops           : 256
OpsCapRemain  : 155
Confidence    : Med
PerfEMWA      : {NetApp.PerfEMWA}

Name          : VICE-08
Utilization   : 2
UtilCapRemain : 60
Latency       : 167
LatCapRemain  : 240
Ops           : 267
OpsCapRemain  : 120
Confidence    : Med
PerfEMWA      : {NetApp.PerfEMWA}

Get the hourly statistics for every node on every controller currently connected to.
.EXAMPLE
	Get-NcNode | .\Get-NcNodePerfCapacity.ps1 -Weekly | FT -Auto

Name    Utilization UtilCapRemain Latency LatCapRemain Ops OpsCapRemain Confidence PerfEMWA
----    ----------- ------------- ------- ------------ --- ------------ ---------- --------
VICE-07           2            65     308          517 263          146        Med {NetApp.PerfEMWA}
VICE-08           2            61     167          242 266          121        Med {NetApp.PerfEMWA}


Get the weekly statistics for every Node on every controller currently connected to.
.EXAMPLE
   $c = Connect-NcController 10.63.171.241 -Transient
   .\Get-NcNodePerfCapacity.ps1 -Node VICE-07 -Hourly -Controller $c


Name          : VICE-07
Utilization   : 2
UtilCapRemain : 65
Latency       : 311
LatCapRemain  : 515
Ops           : 264
OpsCapRemain  : 141
Confidence    : Med
PerfEMWA      : {NetApp.PerfEMWA}

.INPUTS
   string
.OUTPUTS
   NetApp.PerfCapacity
.NOTES
   Copyright NetApp 2016
#>
function Get-NcAggrPerfCapacity {
	[CmdletBinding(DefaultParameterSetName='hourly', 
					SupportsShouldProcess=$false)]
	param(
		[parameter(
			Mandatory=$true
		,   ValueFromPipeline=$true
		,   ValueFromPipelineByPropertyName=$true
		)]
		[Alias('Name')]
		[string[]]$Aggregate
	,
		[parameter(
			Mandatory=$false,
			ParameterSetName="hourly"
		)]
		[switch]$Hourly
	,
		[parameter(
			Mandatory=$false,
			ParameterSetName="daily"
		)]
		[switch]$Daily
	,
		[parameter(
			Mandatory=$false,
			ParameterSetName="weekly"
		)]
		[switch]$Weekly
	,
		[parameter(
			Mandatory=$false,
			ParameterSetName="monthly"
		)]
		[switch]$Monthly
	,
		[parameter(
			Mandatory=$false
		,   ValueFromPipelineByPropertyName=$true
		)]
		[Alias('NcController')]
		[NetApp.Ontapi.Filer.C.NcController]$Controller
	)
	begin
	{
		# set the reporting interval
		$counter = switch ($PsCmdlet.ParameterSetName) 
		{
			"hourly"  { "ewma_hourly"  }
			"daily"   { "ewma_daily"   }
			"weekly"  { "ewma_weekly"  }
			"monthly" {	"ewma_monthly" }
		}
	}
	process 
	{
		# by default disable verbose output.
		$NcSplat = @{
			'Verbose' = $false
		}
		# Add contrller credentials to each query
		if ($Controller)
		{
			$NcSplat.Controller = $Controller
		}
		# Create attributes filter to reduce the ammount of data returned.
		Try
		{
			$AggrAttributes = Get-NcAggr -Template @NcSplat 
			# uuid needed to filter the perf instance data.
			$AggrAttributes.AggregateUuid = ''
			# aggrtype used later to control the output.
			Initialize-NcObjectProperty -Object $AggrAttributes -Name AggrRaidAttributes
			$AggrAttributes.AggrRaidAttributes.AggregateType = '' 
			
		} 
		catch    
		{
			Write-Warning $_.exception.message
			return;
		}
		# add Filters to each query
		Try
		{
			$AggrQuery = Get-NcAggr -Template @NcSplat
			if ($Aggregate)
			{
				$AggrQuery.Name = $Aggregate -join '|'
			}
		} 
		catch    
		{
			Write-Warning $_.exception.message
			return;
		}
		# retrieve the aggregate object
		Foreach ($Aggr in (Get-NcAggr -Query $AggrQuery -Attributes $AggrAttributes @NcSplat))
		{
			Write-Verbose ("processing aggr: {0}  Type: {1}" -f $aggr.name, $Aggr.AggrRaidAttributes.AggregateType )
			$PerfCapacity,$EMWA,$hddInstance,$ssdInstance = $null

			# get the instance data.  there could be more than one here if the aggr
			# uses flash pools...one for the SSDs and another for the HDDs
			$hddInstance = Get-NcPerfInstance -Name resource_headroom_aggr -Uuid ("*{0}*" -f $aggr.AggregateUuid) @NcSplat | 
				Where-Object { $_.Name -match "HDD" } |
				Select-Object -ExpandProperty Name
			$ssdInstance = Get-NcPerfInstance -Name resource_headroom_aggr -Uuid ("*{0}*" -f $aggr.AggregateUuid) @NcSplat |
				Where-Object { $_.Name -match "SSD" } |
				Select-Object -ExpandProperty Name
			if ($hddInstance -ne $null) 
			{
				<# 
				#
				# emwa values
				#
				ops
				optimal_point_ops
				latency
				optimal_point_latency
				utilization
				optimal_point_utilization
				optimal_point_confidence_factor
				#>
				# get the counter data, split it on the comma to get values
				[int64]$_hhdops,
				[int64]$_hhdoptimalPointOps,
				[int64]$_hhdlatency,
				[int64]$_hhdoptimalPointLatency,
				[int64]$_hhdutil,
				[int64]$_hhdoptimalPointUtil, 
				[int]$hhdconfidenceFactor = ((Get-NcPerfData -Name resource_headroom_aggr -Instance $hddInstance @NcSplat).counters | `
					?{ $_.Name -eq $counter }).value -split ","
			
				# this could have been a direct cast but broken out for clarity.
				[NetApp.PerfEMWA[]]$EMWA += New-Object NetApp.PerfEMWA("HHD",
					$_hhdops,
					$_hhdoptimalPointOps,
					$_hhdlatency,
					$_hhdoptimalPointLatency,
					$_hhdutil,
					$_hhdoptimalPointUtil,
					$hhdconfidenceFactor)
			}

			if ($ssdInstance -ne $null) 
			{
				# get the counter data, split it on the comma to get values
				[int64]$_ssdops,
				[int64]$_ssdoptimalPointOps,
				[int64]$_ssdlatency,
				[int64]$_ssdoptimalPointLatency,
				[int64]$_ssdutil,
				[int64]$_ssdoptimalPointUtil, 
				[int]$ssdconfidenceFactor = ((Get-NcPerfData -Name resource_headroom_aggr -Instance $ssdInstance @NcSplat).counters | `
					?{ $_.Name -eq $counter }).value -split ","
				# this could have been a direct cast but broken out for clarity.
				[NetApp.PerfEMWA[]]$EMWA += New-Object NetApp.PerfEMWA("SSD",
					$_ssdops,
					$_ssdoptimalPointOps,
					$_ssdlatency,
					$_ssdoptimalPointLatency,
					$_ssdutil,
					$_ssdoptimalPointUtil,
					$ssdconfidenceFactor)
			}

			if ( $Aggr.AggrRaidAttributes.AggregateType -eq "hybrid" ) 
			{
				Write-Verbose ("Applying Hybrid Weighted average of 20%") 
				# for hybrid aggrs we'll created a weighted average with SSD 
				# representing 20% of the available
				$HHD,$SSD = $null,$null
				$HHD = $EMWA|? {$_.Type -EQ 'HHD'}
				$SSD = $EMWA|? {$_.Type -EQ 'SSD'}

				$UtilPercent = [Math]::Round( ($HHD.Utilization * .8) + ($SSD.Utilization * .2) )
				$UtilCap_Remain = [Math]::Round( ($HHD.UtilizationAvailable * .8) + ($SSD.UtilizationAvailable * .2) )
				$Latency_us = [Math]::Round( ($HHD.Latency * .8) + ($SSD.Latency * .2) )
				$LatCapRemain = [Math]::Round( ($HHD.LatencyAvailable * .8) + ($SSD.LatencyAvailable * .2) )
				$Ops = [Math]::Round( ($HHD.Ops * .8) + ($SSD.Ops * .2) )
				$OpsCapRemain = [Math]::Round( ($HHD.OpsAvailable * .8) + ($SSD.OpsAvailable * .2) )

				if ( [int]$HHD.Confidence -lt [int]$SSD.Confidence) 
				{
					$confidence = $HHD.Confidence
				} else {
					$confidence = $SSD.Confidence
				}
				$PerfCapacity = New-Object NetApp.PerfCapacity($aggr.Name,
					$UtilPercent,
					$UtilCap_Remain,
					$Latency_us,
					$LatCapRemain,
					$Ops,
					$OpsCapRemain,
					$confidence,
					$EMWA)
			}	
			elseif ( $hddInstance -ne $null ) 
			{
					$PerfCapacity = New-Object NetApp.PerfCapacity($Aggr.Name, #hhd
					$EMWA.Utilization,
					$EMWA.UtilizationAvailable,
					$EMWA.Latency,
					$EMWA.LatencyAvailable,
					$EMWA.Ops,
					$EMWA.OpsAvailable,
					$EMWA.Confidence,
					$EMWA)   
			} 
			elseif ( $ssdInstance -ne $null ) 
			{
				$PerfCapacity = New-Object NetApp.PerfCapacity($Aggr.Name, #ssd
					$EMWA.Utilization,
					$EMWA.UtilizationAvailable,
					$EMWA.Latency,
					$EMWA.LatencyAvailable,
					$EMWA.Ops,
					$EMWA.OpsAvailable,
					$EMWA.Confidence,
					$EMWA)   
            
			} else {
				# wat?
			}
        
			$PerfCapacity 
		}
	}
}

<#
.Synopsis
   Retrieve the Aggr Performance Capacity information a.k.a. Headroom.
.DESCRIPTION
   Retrieve the Aggr Performance Capacity information a.k.a. Headroom.
.EXAMPLE
   Get-NcAggr | Get-NcAggrPerfCapacity -Weekly 

Name            Utilization UtilCapRemain Latency       LatCapRemain  Ops           OpsCapRemain
----            ----------- ------------- -------       ------------  ---           ------------
VICE07_aggr1    2           60            4759          16515         247           3727
VICE07_aggr2    14          46            3871          7260          767           748
VICE07_root     36          23            94558         -47685        217           -73
VICE08_aggr1    2           52            6177          23962         217           3539
VICE08_root     53          9             266696        -200208       239           38

Get the weekly statistics for every aggr on every controller we're connected to.
.EXAMPLE
   $c = Connect-NcController 10.63.171.241 -Transient
   Get-NcAggrPerfCapacity -Aggregate VICE07_aggr1 -Hourly -Controller $c


Name            Utilization UtilCapRemain Latency       LatCapRemain  Ops           OpsCapRemain
----            ----------- ------------- -------       ------------  ---           ------------
VICE07_aggr1    0           61            4473          13409         95            3747

.INPUTS
   string
.OUTPUTS
   NetApp.PerfCapacity
.NOTES
   Copyright NetApp 2016
#>
function Get-NcNodePerfCapacity {
	[CmdletBinding(DefaultParameterSetName='hourly', 
		SupportsShouldProcess=$false)]
	param(
		[parameter(
			Mandatory=$true
		,   ValueFromPipeline=$true
		,   ValueFromPipelineByPropertyName=$true
		)]
		[Alias('Name')]
		[string]
		$Node
	,
		[parameter(
			Mandatory=$false,
			ParameterSetName="hourly"
		)]
		[switch]$Hourly
	,
		[parameter(
			Mandatory=$false,
			ParameterSetName="daily"
		)]
		[switch]$Daily
	,
		[parameter(
			Mandatory=$false,
			ParameterSetName="weekly"
		)]
		[switch]$Weekly
	,
		[parameter(
			Mandatory=$false,
			ParameterSetName="monthly"
		)]
		[switch]$Monthly
	,
		[parameter(
			Mandatory=$false
		,   ValueFromPipelineByPropertyName=$true
		)]
		[Alias('NcController')]
		[NetApp.Ontapi.Filer.C.NcController]$Controller
	)
	begin
	{
		# set the reporting interval
		$counter = switch ($PsCmdlet.ParameterSetName) 
		{
			"hourly"  { "ewma_hourly"  }
			"daily"   { "ewma_daily"   }
			"weekly"  { "ewma_weekly"  }
			"monthly" {	"ewma_monthly" }
		}
	}
	process {
		# by default disable verbose output.
		$NcSplat = @{
			'Verbose' = $false
		}
		# Add contrller credentials to each query
		if ($Controller)
		{
			$NcSplat.Controller = $Controller
		}
		# Create attributes filter to reduce the ammount of data returned.
		Try
		{
			$NodeAttributes = Get-NcNode -Template @NcSplat 
			# uuid needed to filter the perf instance data.
			$NodeAttributes.NodeUuid = ''
		} 
		catch    
		{
			Write-Warning $_.exception.message
			return;
		}
		# add Filters to each query
		Try
		{
			$Query = Get-NcNode -Template @NcSplat
			if ($Node)
			{
				$Query.Node = $Node -join '|'
			}
		} 
		catch    
		{
			Write-Warning $_.exception.message
			return;
		}    
		# retrieve the full node object
		Foreach ($n in (Get-NcNode -Query $Query -Attributes $NodeAttributes @NcSplat))
		{
			Write-Verbose ("processing Node: {0}" -f $N.Node)
			$PerfCapacity,$EMWA = $null

			$instance = Get-NcPerfInstance -Name resource_headroom_cpu -Uuid $n.NodeUuid @NcSplat|
				Select-Object -ExpandProperty Name
                
			# get the counter data, split it on the comma to get values
			[int64]$_ops,
			[int64]$_optimalPointOps,
			[int64]$_latency,
			[int64]$_optimalPointLatency,
			[int64]$_util,
			[int64]$_optimalPointUtil, 
			[int]$confidenceFactor = ((Get-NcPerfData -Name resource_headroom_cpu -Instance $instance @NcSplat).counters | `
				?{ $_.Name -eq $counter }).value -split ","
			
			[NetApp.PerfEMWA[]]$EMWA += New-Object NetApp.PerfEMWA("Node",
				$_ops,
				$_optimalPointOps,
				$_latency,
				$_optimalPointLatency,
				$_util,
				$_optimalPointUtil,
				$confidenceFactor)    
		   
			$PerfCapacity = New-Object NetApp.PerfCapacity($N.Node, #node
				$EMWA.Utilization,
				$EMWA.UtilizationAvailable,
				$EMWA.Latency,
				$EMWA.LatencyAvailable,
				$EMWA.Ops,
				$EMWA.OpsAvailable,
				$EMWA.Confidence,
				$EMWA)   
			#return node perf capacity object
			$PerfCapacity
		} # foreach Node
	}
}