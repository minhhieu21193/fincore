# Cost

What the AWS demo environment costs to run, built from AWS's public price list for **ap-southeast-1 (Singapore)**: no guessed prices. Every price, its SKU, the exact offer file and its publication date are in [`docs/cost/prices-ap-southeast-1.json`](cost/prices-ap-southeast-1.json). It was fetched on 2026-10-28 from `pricing.us-east-1.amazonaws.com/offers/v1.0/aws/…` (offer files published 2026-09-11 to 2026-10-27). Spot prices come from AWS's public Spot price feed the same day, and they move. The environment was never deployed (`docs/decisions-log.md`), so these are list-price estimates of the Terraform in this repository, not a bill.

## Headline

| | USD |
|---|---:|
| **Per hour (idle demo, 24/7)** | **1.43** |
| **Per day** | **34.39** |
| **Per 30 days** | **1032** |
| Spot share | 3 of 9 nodes (23 % of node cost); Spot saves $3.43/day against on-demand for the same pool |
| **Cost per 1,000 payments** | **$0.046** at the demo's 10 payments/s; $0.019 at 30/s ([below](#cost-per-1000-payments)) |

`scripts/down.sh` stops all of it except the Terraform state bucket (a few cents a month). For a demo that runs 8 hours, `up.sh` → demo → `down.sh` costs about $11.

## Hourly resources

| Resource | Quantity | Unit price | Per hour | Per day |
|---|---|---:|---:|---:|
| EKS control plane | 1 cluster | $0.10/h | 0.1000 | 2.40 |
| System node group (Vault, Karpenter, CoreDNS, add-ons) | 3 × m7g.large on-demand, one per AZ | $0.102/h | 0.3060 | 7.34 |
| CDE NodePool (payments-api, ledger) | 3 × c7g.large on-demand, one per AZ | $0.0833/h | 0.2499 | 6.00 |
| General NodePool (platform, notifier) | 3 × m7g.large **Spot**, one per AZ | $0.0544/h | 0.1632 | 3.92 |
| Aurora Serverless v2 | writer + reader at the 0.5 ACU floor | $0.20/ACU-h | 0.2000 | 4.80 |
| VPC interface endpoints (ECR ×2, STS, SQS, Secrets Manager) | 5 services × 3 AZs | $0.013/h | 0.1950 | 4.68 |
| NAT gateway | 1 (single NAT for the demo) | $0.059/h | 0.0590 | 1.42 |
| Application Load Balancer | 1, about 1 LCU | $0.0252/h + $0.008/LCU-h | 0.0332 | 0.80 |
| Public IPv4 addresses | NAT + ALB in 3 AZs | $0.005/h | 0.0200 | 0.48 |
| **Total** | | | **1.3263** | **31.83** |

## Monthly resources

| Resource | Quantity | Unit price | Per month |
|---|---|---:|---:|
| EBS gp3 | 9 node root volumes × 40 GB, plus PVCs: Vault 3 × 10, Loki 10, Tempo 10, Prometheus 50, Alertmanager 2 | $0.096/GB-month | 44.35 |
| AWS WAF | 1 web ACL + 5 rules (requests below) | $5 + $1/rule | 10.00 |
| CloudWatch Logs | EKS control plane (5 log types), WAF, CloudTrail: **assumed** 0.5 GB/day, kept 30 days | $0.70/GB + $0.03/GB-month | 10.95 |
| NAT data processed | **assumed** 2 GB/day (ECR, STS, SQS and Secrets Manager use endpoints) | $0.059/GB | 3.54 |
| KMS | 5 customer-managed keys, one per data domain: CDE, platform, backups, Vault unseal, audit | $1/key | 5.00 |
| Secrets Manager | 3 FinCore secrets + the Aurora master secret | $0.40/secret | 1.60 |
| Aurora storage | **assumed** 10 GB | $0.11/GB-month | 1.10 |
| ECR + S3 (state, CloudTrail, backups) | **assumed** 2 GB + 5 GB | $0.10 / $0.025 per GB-month | 0.33 |
| **Total** | | | **76.87** (2.56/day) |

The Route 53 hosted zone already exists (it is looked up, not created), so it is not counted.

## Assumptions, and what moves the number

- **Node count is set by zones, not by load.** Vault (on the system nodes), payments-api, the ledger and the notifier spread over three AZs (`DoNotSchedule`), so each node pool runs at least one node per AZ. At demo load the pods request about 1.6 vCPU and 4 GiB in total (measured on kind), well within these nodes, so the idle cost is the floor. Above it, Karpenter adds Spot nodes for general workloads (about $0.054/h each) and on-demand c7g/m7g nodes for the CDE.
- **The CDE stays on-demand on purpose.** Spot interruptions in the cardholder-data zone would trigger canary analysis noise and reschedules of Vault-credentialed pods. Moving it to Spot (c7g.large at $0.0389/h) would save about $3.20/day; not worth it for payments.
- **Interface endpoints** are assumed to be billed per AZ, as PrivateLink endpoints are deployed (one ENI per subnet). The price list entry says only "per VPC endpoint hour". If they were billed once per endpoint, subtract $3.12/day.
- **Aurora** is costed at its floor (0.5 ACU × 2 instances). Every ACU-hour above that costs $0.20. I/O costs $0.22 per million requests (Aurora Standard; I/O-Optimized would be $0.26/ACU-h and $0.248/GB-month).
- **KMS** counts one key version per key. Every key rotates every 90 days, and AWS charges $1/month for each of the first two rotations, so after six months the five keys cost up to $15/month instead of $5 (+$0.33/day). Requests ($0.03 per 10,000) stay below a cent a day at demo load because SQS and S3 reuse data keys (5 minutes; S3 Bucket Key).
- **Not included:** data transfer to the internet (webhooks to merchants are tiny), CloudTrail data events (not enabled), Support plans, taxes.
- **Biggest levers for a cheaper demo:** run it only when needed (`up.sh`/`down.sh`); one AZ instead of three for a throwaway demo (about −$10/day: 4 fewer nodes, 10 fewer endpoint ENIs, 2 fewer IPs; but no AZ-loss story and no Aurora failover); Gateway endpoints are free, while interface endpoints and NAT are not.

## Small-team profile

[`terraform/envs/demo/profiles/small-team.tfvars`](../terraform/envs/demo/profiles/small-team.tfvars) (`FINCORE_PROFILE=small-team scripts/up.sh`) is the same platform for a team that cannot staff Vault: one NAT gateway, 2 system nodes, and Secrets Manager instead of Vault HA. What it gives up in security is listed in [`compliance-mapping.md`](compliance-mapping.md#small-team-profile).

| | Standard | Small-team | Per day |
|---|---|---|---:|
| System node group (m7g.large on-demand, $0.102/h) | 3, one per AZ (Vault HA needs 3) | 2 | −2.45 |
| NAT gateways | 1 | 1 (one per AZ would add 2 × $0.059/h and 2 public IPs, +$3.07/day) | 0 |
| EBS gp3 ($0.096/GB-month) | 9 roots × 40 GB + Vault 3 × 10 GB + 72 GB other PVCs | 8 roots × 40 GB + 72 GB | −0.22 |
| KMS keys ($1/month) | 5 | 4 (no Vault unseal key) | −0.03 |
| Secrets Manager ($0.40/month) | 4 (`fincore-vault-db-admin`) | 4 (`fincore-ledger-db` instead) | 0 |
| **Per hour** | **1.43** | **1.32** | |
| **Per day** | **34.39** | **31.69** | **−2.70** |
| **Per 30 days** | **1032** | **951** | |
| **Per 1,000 payments** at 10/s | $0.046 | $0.043 | |

The small-team profile saves 8 %. Its real saving is people, not money: nobody has to operate Vault (unseal and recovery keys, Raft snapshots and restores, upgrades, the audit device). The cost floor stays where it is because it is set by the three zones: each node pool runs one node per AZ, and the interface endpoints are billed per AZ. Dropping to two zones would be the next lever (about −$5/day: one CDE node, one Spot node and 5 endpoint ENIs fewer), but it gives up the zone-loss story, so it is not part of this profile.

## Cost per 1,000 payments

Fixed cost divided by payments per hour, plus the per-payment charges:

| Per 1,000 payments | At the demo's traffic (10/s) | At the highest rate kind sustained within the SLOs (30/s) |
|---|---:|---:|
| Fixed (the idle environment above, $1.43/h) | $0.040 | $0.013 |
| Variable: SQS (≤ 3 requests per payment at $0.40/M), WAF (1 request at $0.60/M), Aurora I/O (**assumed** 20 per payment at $0.22/M) | $0.006 | $0.006 |
| **Total** | **$0.046** | **$0.019** |

The 30/s is measured on the laptop (`docs/evidence/phase-3/loadtest-calm/`). On AWS the same footprint serves more before it scales, so the per-payment cost there would be at most this. Above the floor, Aurora adds $0.20 per ACU-hour, Karpenter adds about $0.054 per Spot node-hour, and the ALB adds LCUs (one LCU covers 25 new connections per second).

## OpenCost on kind

OpenCost runs on kind with every node priced as an m7g.large (`gitops/envs/kind/values/opencost.yaml`). Over the 71 minutes of the evidence run's chaos and load test, it allocated **$0.20** of compute to workloads (`docs/evidence/phase-3/opencost-allocation.json`):

| Namespace | USD |
|---|---:|
| kube-system (control plane, CNI) | 0.073 |
| monitoring | 0.028 |
| fincore-cde (payments-api, ledger) | 0.028 |
| fincore-data (database and queue stand-ins) | 0.016 |
| argocd | 0.015 |
| fincore (notifier, webhook sink, traffic) | 0.014 |
| everything else | 0.025 |

Four nodes at that price cost about $0.49 for the same window, so about 60 % of the capacity was idle: normal for a demo-sized platform, and the reason the AWS floor above is set by zones rather than load.
