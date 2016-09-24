# NetApp Performance Capacity Cmdlets

These cmdlets abstract accessing and using the performance capacity (a.k.a. headroom) information reported by ONTAP 9 systems.

Performance Capacity information is automatically collected and stored by the performance archiver service on the controller.  That information is available via the stats API on the controller.

There are two categories:

1) Controller CPU - this is an estimation of the amount of capacity used/available for the controller based on a number of factors which influence, or are influenced by, CPU utilization.

2) Aggregate - this is an estimation of the performance capacity based on aggregate utilization.

The pertient information is the "optimal point", which is the point at which the system has calculated that optimal operations will continue at or below that point.  The optimal point is not a hard rule and can change depending on workload.  Exeeding the recommended optimal point is ok, there's nothing wrong with this.  For example, if the optimal point latency is calculated to be 5ms for a hybrid aggregate, but you're ok with accepting 10ms latency, then exceed it...things will not blow up.

The information is further broken down into different timespans:

* Hourly
* Daily
* Weekly
* Monthly

Use the data for the period of time which most closely matches the length of time that you expect the workload to exist.  For example, the weekly numbers may be lower than the daily and hourly because there are large amounts of resources consumed for weekly backups happening.  This is important information if your workload will be running for more than a couple of days because the combination of backups + new work could cause a performance issue.  However, if your workload will only last a few hours, then it maybe safe to look at the hourly statistics at different times and see that there is more available capacity at a particular time of day, thus a more strenuous workload can be placed temporarily.

Arguably the most important piece of information returned is the confidence factor.  The confidence factor is a value from 0-3 which represents how acurate the system believes it's prediction to be.

* 0 = No data or some error has occurred
* 1 = Low confidence
* 2 = Medium confidence
* 3 = High confidence

Generally speaking, the data will remain confidence 1, or maybe 2, until several time periods of the specified length have passed.  This could mean several months before confidence level 3 is achieved for the monthly measurements.

**Note:** It is extremely important to remember that this information is an estimate based off of historically collected data and is calculated using a weighted moving average methodology.  This means that a mostly idle system will probably not accurately reflect the maximum values.

It is possible to have negative values returned for avaialble capacity (Util_Cap_Remain, Lat_Cap_Remain, Ops_Cap_remain).  This indicates that the system has surpassed it's optimal point capacity.

## Purpose

Broadly speaking, performance capacity allows us to break down the ONTAP system's capacity into three categories: All-Flash, Hybrid, and All-Disk.  Once the "type" of disk desired is selected, use the performance capacity information to choose the best aggregate and node which has enough GiB capacity to host the request and provision there.

## Using the cmdlets

Determining aggregate performance capacity:

```powershell
# show perf capacity for non-root hybrid aggregates
Get-NcAggr -Query @{ AggrRaidAttributes=@{ AggregateType="hybrid"; IsRootAggregate=$false }} | Get-NcAggrPerfCapacity -Daily
```

Determining node performance capacity:

```powershell
# show perf capacity for all nodes in the cluster
Get-NcNode | Get-NcNodePerfCapacity -Daily | ft -AutoSize
```

To get the raw counter values returned by the cmdlet, before they are formated for display, look at the EWMA property:

```
PS C:\Users\Andrew> (Get-NcAggr VICE07_aggr2 | Get-NcAggrPerfCapacity -Weekly).EWMA

HDD_ops                       : 703
HDD_ops_avail                 : 618
HDD_optimal_point_ops         : 1321
HDD_ops_capacity_used         : 53

HDD_latency                   : 4617
HDD_latency_avail             : 10663
HDD_optimal_point_latency     : 15280
HDD_latency_capacity_used     : 30

HDD_utilization               : 19
HDD_utilization_avail         : 40
HDD_optimal_point_utilization : 59
HDD_utilization_capacity_used : 32

HDD_confidence_factor         : 1

SSD_ops                       : 1
SSD_ops_avail                 : 265
SSD_ops_capacity_used         : 0
SSD_optimal_point_ops         : 266

SSD_latency                   : 479
SSD_latency_avail             : 835
SSD_latency_capacity_used     : 36
SSD_optimal_point_latency     : 1314

SSD_utilization               : 1
SSD_utilization_avail         : 61
SSD_utilization_capacity_used : 2
SSD_optimal_point_utilization : 62

SSD_confidence_factor         : 1

```

How the display values are calculated is shown in the cmdlets.
