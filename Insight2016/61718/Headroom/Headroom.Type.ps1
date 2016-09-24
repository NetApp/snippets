if (-not ([System.Management.Automation.PSTypeName]'NetApp.Confidence').Type)
{
    Add-Type -TypeDefinition @"
using System;
namespace NetApp
{
    public enum Confidence { Unknown, Low, Med, High };

    public class PerfEMWA
    {
        public string Type;
        public int Ops;
        public int OptimalPointOps;
        public decimal OpsCapacityUsed
        {
            get { return (Math.Round(((Convert.ToDecimal(this.Ops) / this.OptimalPointOps) * 100))); }
        }
        public int OpsAvailable
        {
            get { return (this.OptimalPointOps - this.Ops); }
        }
        public int Latency;
        public int OptimalPointLatency;
        public decimal LatencyCapacityUsed
        {
            get { return (Math.Round(((Convert.ToDecimal(this.Latency) / this.OptimalPointLatency) * 100))); }
        }
        public decimal LatencyAvailable
        {
            get { return (this.OptimalPointLatency - this.Latency); }
        }
        public int Utilization;
        public int OptimalPointUtilization;
        public decimal UtilizationCapacityUsed
        {
            get { return (Math.Round(((Convert.ToDecimal(this.Utilization) / this.OptimalPointUtilization) * 100))); }
        }
        public decimal UtilizationAvailable
        {
            get { return (this.OptimalPointUtilization - this.Utilization); }
        }
        public Confidence Confidence;

        // custom constructor to streamline building the object in posh;
        public PerfEMWA(
            string type,
            int ops,
            int optimalPointOps,
            int latency,
            int optimalPointLatency,
            int util,
            int optimalPointUtil,
            Confidence confidence)
        {
            Type = type;
            Ops = ops;
            OptimalPointOps = optimalPointOps;
            Latency = latency;
            OptimalPointLatency = optimalPointLatency;
            Utilization = util;
            OptimalPointUtilization = optimalPointUtil;
            Confidence = confidence;
        }
        public PerfEMWA()
        {
            Type = "";
            Ops = 0;
            OptimalPointOps = 0;
            Latency = 0;
            OptimalPointLatency = 0;
            Utilization = 0;
            OptimalPointUtilization = 0;
            Confidence = 0;
        }
    }

    public class PerfCapacity
    {
        public string Name;
        public int Utilization;
        public int UtilCapRemain;
        public int Latency;
        public int LatCapRemain;
        public int Ops;
        public int OpsCapRemain;
        public Confidence Confidence;
        public PerfEMWA[] PerfEMWA;
        
        // custom constructor to streamline building the object in posh;
        public PerfCapacity(
            string name,
            int util,
            int optimalPointUtil,
            int latency,
            int optimalPointLatency,
            int ops,
            int optimalPointops,
            Confidence confidence,
            PerfEMWA[] EMWA)
        {
            Name = name;
            Utilization = util;
            UtilCapRemain = optimalPointUtil;
            Latency = latency;
            LatCapRemain = optimalPointLatency;
            Ops = ops;
            OpsCapRemain = optimalPointops;
            Confidence = confidence;
            PerfEMWA = EMWA;
        }
        public PerfCapacity()
        {
            Name = "";
            Utilization = 0;
            UtilCapRemain = 0;
            Latency = 0;
            LatCapRemain = 0;
            Ops = 0;
            OpsCapRemain = 0;
            Confidence = 0;
        }
    }
}

"@
}