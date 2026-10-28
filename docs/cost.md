# Cost

What the AWS demo environment costs to run, built from AWS's public price list for **ap-southeast-1 (Singapore)**: no guessed prices. Every price, its SKU, the exact offer file and its publication date are in [`docs/cost/prices-ap-southeast-1.json`](cost/prices-ap-southeast-1.json). It was fetched on 2026-10-28 from `pricing.us-east-1.amazonaws.com/offers/v1.0/aws/…` (offer files published 2026-09-11 to 2026-10-27). Spot prices come from AWS's public Spot price feed the same day, and they move. The environment was never deployed (`docs/decisions-log.md`), so these are list-price estimates of the Terraform in this repository, not a bill.

## Headline

| | USD |
|---|---:|
| **Per hour (idle demo, 24/7)** | **1.43** |
| **Per day** | **34.33** |
| **Per 30 days** | **1030** |
| Spot share | 3 of 9 nodes (23 % of node cost); Spot saves $3.43/day against on-demand for the same pool |
| Cost per 1,000 payments | pending (see [below](#cost-per-1000-payments)) |

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
| KMS | 3 customer-managed keys (platform, Vault unseal, audit) | $1/key | 3.00 |
| Secrets Manager | 3 FinCore secrets + the Aurora master secret | $0.40/secret | 1.60 |
| Aurora storage | **assumed** 10 GB | $0.11/GB-month | 1.10 |
| ECR + S3 (state, CloudTrail, backups) | **assumed** 2 GB + 5 GB | $0.10 / $0.025 per GB-month | 0.33 |
| **Total** | | | **74.87** (2.50/day) |

The Route 53 hosted zone already exists (it is looked up, not created), so it is not counted.

## Assumptions, and what moves the number

- **Node count is set by zones, not by load.** Vault (on the system nodes), payments-api, the ledger and the notifier spread over three AZs (`DoNotSchedule`), so each node pool runs at least one node per AZ. At demo load the pods request about 1.6 vCPU and 4 GiB in total (measured on kind), well within these nodes, so the idle cost is the floor. Above it, Karpenter adds Spot nodes for general workloads (about $0.054/h each) and on-demand c7g/m7g nodes for the CDE.
- **The CDE stays on-demand on purpose.** Spot interruptions in the cardholder-data zone would trigger canary analysis noise and reschedules of Vault-credentialed pods. Moving it to Spot (c7g.large at $0.0389/h) would save about $3.20/day; not worth it for payments.
- **Interface endpoints** are assumed to be billed per AZ, as PrivateLink endpoints are deployed (one ENI per subnet). The price list entry says only "per VPC endpoint hour". If they were billed once per endpoint, subtract $3.12/day.
- **Aurora** is costed at its floor (0.5 ACU × 2 instances). Every ACU-hour above that costs $0.20. I/O costs $0.22 per million requests (Aurora Standard; I/O-Optimized would be $0.26/ACU-h and $0.248/GB-month).
- **Not included:** data transfer to the internet (webhooks to merchants are tiny), CloudTrail data events (not enabled), Support plans, taxes.
- **Biggest levers for a cheaper demo:** run it only when needed (`up.sh`/`down.sh`); one AZ instead of three for a throwaway demo (about −$10/day: 4 fewer nodes, 10 fewer endpoint ENIs, 2 fewer IPs; but no AZ-loss story and no Aurora failover); Gateway endpoints are free, while interface endpoints and NAT are not.

## Cost per 1,000 payments

**Pending.** This needs the sustained throughput from the Phase 3 load test (`docs/evidence/phase-3/loadtest.md`), which is not measured yet: so far kind saturates its 6-CPU VM below 60 payments/s (decisions log, 2026-10-28).
