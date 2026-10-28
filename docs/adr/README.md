# Architecture decision records

Short records of the decisions that shape FinCore: the context, the choice,
what it costs, and what would make us revisit it. Costs are in
[`docs/cost.md`](../cost.md).

| # | Decision | Status |
|---|---|---|
| [0001](0001-karpenter-over-cluster-autoscaler.md) | Karpenter, not Cluster Autoscaler | Accepted |
| [0002](0002-argo-cd-over-flux.md) | Argo CD with Argo Rollouts, not Flux with Flagger | Accepted |
| [0003](0003-vault-and-secrets-manager.md) | Vault for dynamic credentials, Secrets Manager for static secrets (not Secrets Manager only) | Accepted |
| [0004](0004-sqs-outbox-over-kafka.md) | Transactional outbox to SQS, not Kafka / MSK | Accepted |
| [0005](0005-aurora-serverless-v2.md) | Aurora Serverless v2, not provisioned instances | Accepted |

## Considered, not chosen

| Option | Why not (for FinCore today) | Would revisit when |
|---|---|---|
| **Service mesh (Istio, Linkerd)** for mTLS and traffic splitting | NetworkPolicies already enforce the zone boundary; the only east-west hop inside the zone is payments-api → ledger. Argo Rollouts splits traffic with replica ratios (kind) or ALB weights (AWS). A mesh adds a sidecar or ztunnel per node, a control plane and a new failure mode, for one hop. | mTLS between services becomes a compliance requirement, or the number of internal hops grows past a handful |
| **API gateway (Kong, Apigee)** | One public API behind ALB + WAF: TLS, managed rule groups and rate limiting are covered. Per-merchant API keys and quotas live in the service. | Many public APIs, per-plan quotas, a developer portal |
| **Connection pooler (PgBouncer, RDS Proxy, ProxySQL)** | A fixed connection budget (pods × pool ≤ 100) keeps Aurora well within its limits; the load test showed the real problem was elsewhere (postmortem 2026-10-28). Transaction pooling also breaks session features the ledger uses (`SET ROLE` for Vault-issued users). | Replica counts outgrow the budget, or Lambda-style bursty clients appear |
| **Multi-region active-active** | Payments need one source of truth for the ledger; active-active means conflict resolution on money. Multi-AZ (3 AZs, Aurora reader in another AZ) plus tested restore gives the availability and RPO/RTO the business case needs at a fraction of the cost. | A regulator or contract requires regional failover; then active-passive with Aurora Global Database first |
| **Kafka / MSK** | See [0004](0004-sqs-outbox-over-kafka.md). | |
| **Self-managed PostgreSQL on Kubernetes (CloudNativePG)** | Backups, failover, patching and storage become ours; Aurora's are tested at a scale we never will. kind uses a single PostgreSQL pod only as a stand-in. | Cost at very large scale, or a portability requirement |
