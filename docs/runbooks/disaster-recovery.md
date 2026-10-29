# Disaster recovery

Rebuild FinCore after losing the cluster, or restore one namespace from backups.

**kind:** `scripts/kind-up.sh --restore` does every step below in order. Drill and RTO/RPO: [`docs/evidence/phase-3/dr-drill.md`](../evidence/phase-3/dr-drill.md).

**AWS:** the steps below are manual and have not been exercised yet ([`aws-demo-day.md`](../aws-demo-day.md), item f).

## What the backups hold (AWS)

| Backup | Contents | Every |
|---|---|---|
| Velero `velero-cluster-state` | Namespaces `vault`, `fincore`, `external-secrets`, `argocd`, Secrets included | hourly, kept 7 days |
| Velero `velero-cde-without-secrets` | Namespace `fincore-cde` **without its Secrets**: the backup bucket holds no copy of a CDE credential | hourly at :05, kept 7 days |
| Vault Raft snapshot | Vault's data (policies, auth, database engine) | 15 min |
| Aurora | Continuous backups, point-in-time recovery | continuous, 7 days |

None of these hold the zone's Secrets:
- External Secrets recreates them from Secrets Manager: `payments-db`, `db-admin`, and `vault-db-admin` (or `ledger-db` in the small-team profile).
- cert-manager re-issues `vault-ca`.
- The ledger's Vault-issued database credentials are never Kubernetes Secrets: Vault Agent renders them inside the pod.

## Restore (AWS)

1. **Stop scheduled backups** so a half-restored cluster does not become the newest backup:
   ```
   for s in velero-cluster-state velero-cde-without-secrets; do
     kubectl -n velero patch schedule "$s" --type merge -p '{"spec":{"paused":true}}'
   done
   ```
2. **Database** (only if data was lost): restore Aurora to a point in time, then point the environment at the new cluster ([database failover](db-failover.md)).
3. **Vault** (Vault profile only): restore the newest `vault/<UTC time>.snap` from the backup bucket with `vault operator raft snapshot restore -force` on the active node. Restart it, then the standbys rejoin. It unseals with the same KMS key ([Vault sealed](vault-sealed.md)).
4. **Cluster state:**
   ```
   kubectl -n velero exec deploy/velero -- /velero restore create --from-schedule velero-cluster-state --wait
   kubectl -n velero exec deploy/velero -- /velero restore create --from-schedule velero-cde-without-secrets --wait
   ```
5. **Wait for the zone's ExternalSecrets before counting the zone as up.** Pods that start before their Secret exists sit in `CreateContainerConfigError`. A Running pod is not proof that the zone is up.
   ```
   kubectl -n fincore-cde wait externalsecret --all --for=condition=Ready --timeout=10m
   kubectl -n fincore-cde get secret payments-db db-admin            # plus vault-db-admin or ledger-db
   ```
   If one stays not Ready, run `kubectl -n fincore-cde describe externalsecret <name>`. Usual causes:
   - the ClusterSecretStore isn't Ready;
   - the External Secrets role was denied `kms:Decrypt`. CloudTrail shows an `AccessDenied` with the secret's ARN in the encryption context.
6. **Then the workloads:** re-run the database bootstrap (`argocd app sync cde-base`, whose db-init hook re-applies the passwords). Restart whatever started too early:
   ```
   kubectl argo rollouts -n fincore-cde restart payments-api
   kubectl argo rollouts -n fincore-cde restart ledger
   kubectl -n fincore-cde get rollouts        # both Healthy
   ```
7. **The zone is up** when its ExternalSecrets are Ready, both Rollouts are Healthy, and a payment succeeds end to end ([`aws-demo-day.md`](../aws-demo-day.md), item a). The RTO runs from the disaster to that payment.
8. **Resume the schedules** (step 1 with `"paused":false`). Afterwards, check that the next `velero-cde-without-secrets` backup completes.

## After

- Ledger imbalance is 0, and the outbox backlog drains ([ledger imbalance](ledger-imbalance.md)).
- Record the RTO, and the RPO (the age of the newest backup used), in the incident notes.
