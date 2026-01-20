### Key Resources and Limits
Oracle Cloud's **Always Free** tier provides indefinite access to specific resources with strict limits, available in your home region. These never expire if you stay within caps.

- **Compute** — Up to 2 AMD micro instances (each 1/8 OCPU, 1 GB RAM) + Arm-based Ampere A1 Flex (total 4 OCPUs, 24 GB RAM, configurable across up to 4 instances).
- **Storage** — 200 GB total block/boot volume + 20 GB object/archive storage (combined tiers post-trial) + 50,000 API requests/month.
- **Databases** — 2 Autonomous Databases (each 1 OCPU, 20 GB storage) + 1 NoSQL or HeatWave instance with limits.
- **Networking** — 1 Flexible Load Balancer (10 Mbps), 1 Network Load Balancer, up to 2 VCNs, 50 Site-to-Site VPN connections, 10 TB outbound data transfer/month.
- **Other** — Monitoring, notifications, logging, vault secrets, and more with specified caps.

### Maximizing Value
Configure one powerful Arm instance with all 4 OCPUs and 24 GB RAM for demanding tasks like self-hosting. Combine with 2 micro instances for lightweight services. Use full 200 GB block storage by attaching volumes to instances. Keep instances active (CPU/network/memory >20% over 7 days) to avoid reclamation. Community tips suggest upgrading to Pay As You Go (PAYG) while staying in free limits for better stability and availability, though pure Always Free works indefinitely if compliant.

### Risks and Considerations
Idle instances risk reclamation after 7 consecutive low-utilization days. Capacity varies by region; some users report creation difficulties without PAYG. No SLAs or full support for Always Free-only accounts. Outbound port 25 blocked by default.

| Category | Resource | Exact Limits | Notes |
|----------|----------|--------------|-------|
| Compute (AMD) | VM.Standard.E2.1.Micro | Up to 2 instances | Each: 1/8 OCPU (burstable), 1 GB RAM; Oracle Linux/Ubuntu/CentOS images |
| Compute (Arm) | VM.Standard.A1.Flex | Total 4 OCPUs + 24 GB RAM (3,000 OCPU hours + 18,000 GB hours/month) | Flexible allocation; up to 4 instances; min boot volume 47-50 GB each |
| Block Storage | Boot + Block Volumes | 200 GB total combined | 5 backups total; home region only |
| Object/Archive Storage | Standard/Infrequent/Archive | 20 GB combined (post-trial Always Free) | 50,000 API requests/month; 30 GB if paid/trial |
| Autonomous Database | Transaction Processing, Data Warehouse, JSON, APEX | Up to 2 databases | Each: 1 OCPU, 20 GB storage, 20 sessions max |
| NoSQL Database | Tables | 1 database, 3 tables | 25 GB/table, 133M reads/writes/month |
| HeatWave MySQL | Standalone instance | 1 instance | 50 GB data + 50 GB backup |
| Load Balancing | Flexible Load Balancer | 1 (10 Mbps min/max) | 16 listeners/backend sets |
| Network Load Balancer | Instance | 1 | 50 listeners/backend sets |
| Networking | VCNs | Up to 2 (free-only tenancy) | IPv4/IPv6; port 25 blocked |
| Outbound Data | Transfer | 10 TB/month | - |
| Vault | Secrets + Keys | 150 secrets, 20 HSM key versions | - |

---

### Comprehensive Overview of Oracle Cloud Always Free Tier
Oracle Cloud Infrastructure's Always Free tier offers a set of resources available for an unlimited time, distinct from the 30-day $300 promotional trial credits. These resources are provisioned in your home region and labeled as "Always Free eligible." Staying within limits ensures no charges, but exceeding them (without upgrading) can lead to disablement or deletion of excess resources.

#### Compute Resources: Getting the Most Power
The standout value comes from compute instances. You get:
- Two VM.Standard.E2.1.Micro (AMD) instances: Each provides 1/8 OCPU (burstable), 1 GB RAM, and choice of Oracle Linux Cloud Developer, Oracle Linux, Ubuntu, or CentOS images. Networking up to 50 Mbps public or 480 Mbps private.
- VM.Standard.A1.Flex (Ampere Arm): Total pool of 4 OCPUs and 24 GB memory, equivalent to 3,000 OCPU hours and 18,000 GB hours per month. Allocate flexibly—one large instance with full 4 cores/24 GB for heavy workloads (e.g., media servers, VPNs, app hosting) or split across up to 4 instances.

To maximize: Create a single Arm instance with maximum allocation for best performance. Minimum boot volume is ~47-50 GB per instance, counting against block storage. Instances must use eligible images; Oracle Linux Cloud Developer requires ≥8 GB RAM.

**Reclamation Risk**: Oracle may reclaim idle instances if, over any 7-day period, 95th percentile CPU <20%, network <20%, or memory <20% (A1 only). Community advice: Run lightweight processes (e.g., monitoring scripts) to maintain utilization.

#### Storage: Block, Object, and Archive
- **Block/Boot Volume**: 200 GB total across all boot and attached block volumes, plus 5 backups. Default boot ~50 GB; attach additional volumes to maximize usable space (~150 GB extra after one boot volume).
- **Object Storage**: Post-trial Always Free: 20 GB combined across Standard, Infrequent Access, and Archive tiers. During trial or on paid: up to 30 GB (10 GB each tier). Includes 50,000 API requests/month.

To maximize: Use block for high-performance needs (attached to compute) and object for backups/archives.

#### Databases: Powerful Options Included
- **Autonomous Databases**: Two instances total (Transaction Processing, Data Warehouse, JSON, or APEX). Each: 1 fixed OCPU, 20 GB Exadata storage, max 20 sessions. Serverless on Exadata infrastructure.
- **NoSQL**: One database, 3 tables (25 GB each), 133 million reads/writes monthly.
- **HeatWave MySQL**: One standalone single-node instance, 50 GB data + 50 GB backup.

To maximize: Use Autonomous for development/testing or low-traffic apps; HeatWave for analytics/ML.

#### Networking and Connectivity
- One Flexible Load Balancer (10 Mbps, newer tenancies) or Micro (older).
- One Network Load Balancer.
- Up to 2 VCNs (free-only), 50 Site-to-Site IPSec VPN connections.
- 10 TB outbound data transfer monthly.
- 10 GB/month VCN flow logs.

To maximize: Set up VPN for secure tunneling or load balance across instances.

#### Observability, Security, and Additional Services
- Monitoring: 500M ingestion datapoints, 1B retrieval.
- Notifications: 1M HTTPS + 1,000 email/month.
- Logging: 10 GB/month.
- Application Performance Monitoring: 1,000 tracing events + 10 synthetic monitors/hour.
- Vault: 150 secrets + 20 HSM-protected key versions.
- Email Delivery: 3,000/month (or 100/day in some listings).
- Bastions: Up to 5.
- Certificates: 5 private CAs + 150 TLS certificates.

These enable full-stack monitoring and security without extra cost.

#### Community Insights on Maximization and Stability
Users on Reddit (e.g., r/oraclecloud, r/selfhosted) frequently report using the Arm instance for self-hosting suites like Jellyfin, *arr apps, or game servers. Common tips:
- Upgrade to Pay As You Go early: Keeps Always Free resources free, accesses larger capacity pools (easier instance creation), and reduces termination risks.
- Pure Always Free accounts face occasional "out of capacity" errors or idle reclamations.
- Back up data externally; some report abrupt terminations (though often linked to inactivity or violations).
- Choose home region carefully during signup for Ampere availability.

No charges occur if limits are respected; exceeding requires upgrade or resources may be disabled/deleted after grace periods.

#### Limitations and Conditions
- Home region only for key resources (compute, databases, block).
- No SLAs; limited/community support only.
- One account per person; violations risk suspension.
- Post-trial object storage drops to 20 GB if not upgraded.
- Port 25 outbound blocked (request exemption if needed).

This tier offers exceptional value for personal projects, learning, or lightweight production—especially the 4-core/24 GB Arm instance rivaling paid VPS offerings elsewhere.

**Key Citations**
- Oracle Cloud Always Free Resources Documentation: https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
- Oracle Cloud Free Tier Overview: https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier.htm
- Oracle Cloud Free Tier Marketing Page: https://www.oracle.com/cloud/free/
- Oracle Cloud Free Tier FAQ: https://www.oracle.com/cloud/free/faq
- Reddit Discussions on Limits and Tips: https://www.reddit.com/r/oraclecloud/ (various threads on maximization, PAYG upgrade, and idle policies)