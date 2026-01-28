# Oracle Cloud Always Free Tier Guide

This guide explains Oracle Cloud Infrastructure's Always Free tier resources and how to maximize their value.

## Overview

Oracle Cloud's **Always Free** tier provides indefinite access to specific resources with strict limits, available in your home region. These resources never expire if you stay within the caps.

## Key Resources and Limits

### Compute Resources

- **AMD Micro Instances**: Up to 2 instances
  - Each: 1/8 OCPU (burstable), 1 GB RAM
  - Shape: `VM.Standard.E2.1.Micro`
  - Images: Oracle Linux, Ubuntu, CentOS
  
- **ARM A1 Flex Instances**: Total 4 OCPUs + 24 GB RAM
  - Shape: `VM.Standard.A1.Flex`
  - Flexible allocation across up to 4 instances
  - Minimum boot volume: 47-50 GB per instance
  - Equivalent to 3,000 OCPU hours and 18,000 GB hours per month

### Storage

- **Block/Boot Volumes**: 200 GB total combined
  - Includes 5 backups total
  - Home region only
  
- **Object/Archive Storage**: 20 GB combined (post-trial Always Free)
  - 50,000 API requests/month
  - 30 GB if on paid/trial tier

### Databases

- **Autonomous Databases**: Up to 2 instances
  - Each: 1 OCPU, 20 GB storage, 20 sessions max
  - Types: Transaction Processing, Data Warehouse, JSON, APEX
  
- **NoSQL Database**: 1 database, 3 tables
  - 25 GB per table
  - 133 million reads/writes per month
  
- **HeatWave MySQL**: 1 standalone instance
  - 50 GB data + 50 GB backup

### Networking

- **Load Balancers**: 
  - 1 Flexible Load Balancer (10 Mbps)
  - 1 Network Load Balancer
  
- **VCNs**: Up to 2 (free-only tenancy)
  - IPv4/IPv6 support
  - Port 25 outbound blocked by default
  
- **Data Transfer**: 10 TB outbound per month
- **VPN**: 50 Site-to-Site IPSec VPN connections

### Other Services

- **Monitoring**: 500M ingestion datapoints, 1B retrieval
- **Notifications**: 1M HTTPS + 1,000 email/month
- **Logging**: 10 GB/month
- **Vault**: 150 secrets + 20 HSM key versions
- **Email Delivery**: 3,000/month
- **Bastions**: Up to 5
- **Certificates**: 5 private CAs + 150 TLS certificates

## Detailed Limits Table

| Category | Resource | Exact Limits | Notes |
|----------|----------|--------------|-------|
| Compute (AMD) | VM.Standard.E2.1.Micro | Up to 2 instances | Each: 1/8 OCPU (burstable), 1 GB RAM |
| Compute (Arm) | VM.Standard.A1.Flex | Total 4 OCPUs + 24 GB RAM | Flexible allocation; up to 4 instances; min boot volume 47-50 GB each |
| Block Storage | Boot + Block Volumes | 200 GB total combined | 5 backups total; home region only |
| Object/Archive Storage | Standard/Infrequent/Archive | 20 GB combined (post-trial) | 50,000 API requests/month |
| Autonomous Database | Transaction Processing, Data Warehouse, JSON, APEX | Up to 2 databases | Each: 1 OCPU, 20 GB storage, 20 sessions max |
| NoSQL Database | Tables | 1 database, 3 tables | 25 GB/table, 133M reads/writes/month |
| HeatWave MySQL | Standalone instance | 1 instance | 50 GB data + 50 GB backup |
| Load Balancing | Flexible Load Balancer | 1 (10 Mbps min/max) | 16 listeners/backend sets |
| Network Load Balancer | Instance | 1 | 50 listeners/backend sets |
| Networking | VCNs | Up to 2 (free-only tenancy) | IPv4/IPv6; port 25 blocked |
| Outbound Data | Transfer | 10 TB/month | - |
| Vault | Secrets + Keys | 150 secrets, 20 HSM key versions | - |

## Maximizing Value

### Compute Strategy

1. **Single Powerful ARM Instance**: Configure one ARM instance with all 4 OCPUs and 24 GB RAM for demanding tasks like:
   - Self-hosting applications (Jellyfin, *arr apps)
   - Game servers
   - Media servers
   - VPNs
   - Application hosting

2. **Combined Approach**: Use 2 AMD micro instances for lightweight services alongside the ARM instance

3. **Flexible Allocation**: Split ARM resources across multiple instances if needed (up to 4 instances)

### Storage Strategy

- Use full 200 GB block storage by attaching volumes to instances
- Default boot volume is ~50 GB; attach additional volumes to maximize space
- Use object storage for backups and archives

### Avoiding Reclamation

**Important**: Oracle may reclaim idle instances if, over any 7-day period:
- 95th percentile CPU < 20%
- Network < 20%
- Memory < 20% (A1 instances only)

**Tips to avoid reclamation**:
- Run lightweight monitoring scripts to maintain utilization
- Keep instances active with regular workloads
- Monitor resource usage regularly

## Community Insights

Users frequently report:

- **Upgrade to Pay As You Go (PAYG)**: 
  - Keeps Always Free resources free
  - Accesses larger capacity pools (easier instance creation)
  - Reduces termination risks
  - Better stability and availability

- **Pure Always Free accounts**:
  - May face occasional "out of capacity" errors
  - Higher risk of idle reclamations
  - No SLAs or full support

- **Best Practices**:
  - Back up data externally
  - Choose home region carefully during signup for Ampere availability
  - Monitor resource usage to stay within limits

## Limitations and Conditions

- **Home region only**: Key resources (compute, databases, block storage) are limited to your home region
- **No SLAs**: Limited/community support only for Always Free accounts
- **One account per person**: Violations risk suspension
- **Post-trial storage**: Object storage drops to 20 GB if not upgraded to paid tier
- **Port 25 blocked**: Outbound port 25 is blocked by default (request exemption if needed)

## Getting Started

1. **Create Account**: Sign up at https://signup.cloud.oracle.com/
   - Valid credit card required (no virtual or prepaid cards)
   - Credit card is used for verification only; no charges if you stay within Always Free limits

2. **Choose Region**: Select your home region carefully
   - Consider Ampere availability for ARM instances
   - Region cannot be changed after account creation

3. **Use CloudCradle**: Let CloudCradle automate the setup process
   - Automatically discovers available resources
   - Validates against Free Tier limits
   - Generates Terraform configuration

## References

- [Oracle Cloud Always Free Resources Documentation](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
- [Oracle Cloud Free Tier Overview](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier.htm)
- [Oracle Cloud Free Tier Marketing Page](https://www.oracle.com/cloud/free/)
- [Oracle Cloud Free Tier FAQ](https://www.oracle.com/cloud/free/faq)
- [Reddit: r/oraclecloud](https://www.reddit.com/r/oraclecloud/) - Community discussions on limits, tips, and experiences
