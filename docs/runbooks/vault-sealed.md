# Vault sealed or unavailable

Vault (3 nodes, Raft storage, TLS) issues the ledger's database users: short-lived PostgreSQL users, renewed by the Vault Agent sidecar (3 min on kind, 1 h on AWS). It unseals itself with a KMS key (AWS KMS; a local KMS emulator on kind). No human holds an unseal key; the 5 recovery keys (threshold 3) are kept offline.

**Impact if Vault is down:** running ledger pods keep working until their current database user expires. After that their new connections fail, and new ledger pods cannot start: the injector fails closed and a ledger pod is never created without its agent. Payments then fail (see [payment failures](payment-failures-spike.md)).

## Check

```
for i in 0 1 2; do kubectl -n vault exec vault-$i -c vault -- vault status -format=json | jq -c '{initialized, sealed, ha_enabled, raft_committed_index}'; done
kubectl -n vault get pods -o wide
kubectl -n vault logs vault-0 -c vault --since=15m | grep -iE 'seal|kms|raft|error' | tail -20
```

| Symptom | Cause | Action |
|---|---|---|
| `sealed: true` on every node, logs show KMS errors | Vault cannot reach or use its KMS key | AWS: the key exists and is enabled, Pod Identity role `<name>-vault` has `kms:Decrypt`, the node can reach the KMS endpoint. kind: `kubectl -n vault get pods -l app.kubernetes.io/name=local-kms` |
| One node sealed or not ready, two fine | Lost a node; quorum holds (Raft tolerates 1 of 3) | Let it reschedule; `updateStrategy` is OnDelete, so restart a stuck node with `kubectl -n vault delete pod vault-N` (one at a time, standbys first) |
| Two or three nodes gone | Raft quorum lost; Vault is read-only/unavailable | Bring nodes back first (they rejoin with their data). If storage is lost: restore from snapshot (below) |
| `initialized: false` on a fresh cluster | New cluster | `scripts/vault-init.sh` (once), or restore |
| Ledger Vault Agent logs `permission denied` | Policy or Kubernetes auth role changed | Re-run the configuration job: Argo CD → `vault-config` → Sync (idempotent) |

## Restore from a Raft snapshot

Snapshots are taken every 15 minutes (`vault-snapshot` CronJob) to the backup bucket. They are useless without the original KMS key, so the key is never deleted while snapshots exist.

- kind: `scripts/kind-up.sh --restore` restores the newest snapshot into a fresh cluster (`docs/evidence/phase-3/dr-drill.md`).
- In place (AWS): with a token from `vault operator generate-root` (recovery keys, 3 of 5): `vault operator raft snapshot restore -force <file>`. Vault restarts on the restored data and unseals with the same KMS key.

## Never

- Never disable the injector's fail-closed policy to "get the ledger up".
- Never store recovery keys or a root token in the cluster or in git.
