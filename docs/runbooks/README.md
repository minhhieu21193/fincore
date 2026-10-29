# Runbooks

One page per situation an on-call engineer meets. Every alert in
`gitops/platform/slo` links to one of them.

| Runbook | Alerts / symptoms |
|---|---|
| [Payment failures spike](payment-failures-spike.md) | `PaymentsAvailabilityBudgetBurn`, `PaymentsLatencyBudgetBurn`, `PaymentsAPIUnavailable`, `LedgerUnavailable` |
| [Canary rollback](canary-rollback.md) | A Rollout `Degraded` / `RolloutAborted`, a release that will not promote |
| [Vault sealed or unavailable](vault-sealed.md) | Ledger pods not starting, "permission denied" or "connection refused" from Vault Agent |
| [Node pressure](node-pressure.md) | Evictions, `MemoryPressure`/`DiskPressure`, pods `Pending` |
| [Database failover](db-failover.md) | Aurora failover (planned or not), PostgreSQL restart, `connection refused` / `57P03` |
| [Ledger imbalance](ledger-imbalance.md) | `LedgerImbalance` |
| [Disaster recovery](disaster-recovery.md) | Cluster lost or a namespace destroyed: restore from Velero, Vault snapshots and Aurora |

Conventions: `kubectl` runs against the cluster in question (kind:
`export KUBECONFIG=.kube/kind-config`). Dashboards are in Grafana's FinCore
folder. Times are UTC. Anything you change by hand during an incident goes in
the incident channel, and in the change log afterwards.
