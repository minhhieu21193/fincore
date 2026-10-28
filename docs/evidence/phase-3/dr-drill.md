# Disaster recovery drill on kind

2026-10-28: the whole cluster was deleted while payments were flowing, then rebuilt from the backup store with `scripts/kind-up.sh --restore`.

| | |
|---|---|
| **RTO** (disaster to first successful payment) | **18 min 14 s** |
| **RPO** (age of the newest data backup at the disaster) | **8 min 36 s** (PostgreSQL dump); Vault snapshot 8 min 36 s; Velero cluster state 8 min 30 s |
| Payments | 122016 before; 117729 restored, including all 117665 created before the newest dump started; 4287 made after the dump were lost (within the RPO) |
| Ledger | 105476 of 109489 transactions restored; imbalance 0 before, **0 after** |
| Sample payment (captured before the dump) | `15dba1e0-0496-40dd-929d-4dcba1a3c775`: captured after the restore |
| Vault | 3/3 nodes initialised and unsealed by the original KMS key, with the original data (policies, Kubernetes auth, database engine); the ledger received fresh Vault-issued credentials |
| Restored from | Velero backup `velero-cluster-state-20261028214508`, vault/20261028T214502Z.snap postgres/20261028T214502Z.sql.gz  |

## Timeline (UTC)

| Time | Step |
|---|---|
| 21:53:38 | Disaster: cluster deletion starts |
| 21:53:44 | Cluster gone |
| 21:53:44 | `kind-up.sh --restore` starts (new cluster, images from the registry, Argo CD) |
| 21:58:08 | secrets restored from velero-cluster-state-20261028214508 (4 emulated Secrets Manager entries and the KMS seed) |
| 22:07:05 | snapshot restored; the temporary recovery key and root token no longer exist |
| 22:07:44 | data restored from vault/20261028T214502Z.snap and postgres/20261028T214502Z.sql.gz |
| 22:11:04 | restore stages done in 871s |
| 22:11:49 | FinCore is up on kind (45s) |
| 22:11:49 | Every application Synced and Healthy |
| 22:11:52 | First successful payment |

The RPO is bounded by the backup schedule (every 15 minutes on kind). On AWS, Aurora's continuous backups give point-in-time recovery to within about 5 minutes, and the same Vault snapshot and Velero schedules apply.
Full log: `dr-drill.log`.
