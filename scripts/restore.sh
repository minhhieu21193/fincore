#!/usr/bin/env bash
# Restore stages of a disaster recovery, run by `scripts/kind-up.sh --restore`
# once the new cluster's root application is in place with restoreHold=true.
# Can be re-run by hand if a stage timed out: each stage is idempotent or
# refuses to run twice (vault-init.sh --restore needs an uninitialised Vault).
#
#   1. secrets  Velero restores the labelled secrets (emulated Secrets Manager, KMS seed)
#   2. Vault    the newest Raft snapshot over a fresh Vault (same KMS key)
#   3. data     the newest pg_dumpall into the empty PostgreSQL
#   then the restore hold is released and GitOps brings up the rest.
#
# Vault runs a single node during the restore (restoreValues in the
# app-of-apps); its other two nodes join after the hold is released, and
# kind-up then waits for all three.
#
# STAGE_WAIT (default 1800 s): how long each stage waits for its component.
# On kind most of it is image pulls into the brand-new nodes.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl jq curl
STAGE_WAIT="${STAGE_WAIT:-1800}"

RESTORE_START=$SECONDS
work="$(mktemp -d)"
log "restore 1/3: secrets (Velero, from the newest cluster-state backup)"
wait_for "Velero" "$STAGE_WAIT" kubectl -n velero rollout status deployment/velero --timeout=5s
wait_for "the backup location" 300 bash -c \
  "[[ \$(kubectl -n velero get backupstoragelocations.velero.io default -o jsonpath='{.status.phase}' 2>/dev/null) == Available ]]"
completed_backups() {
  kubectl -n velero get backups.velero.io -l velero.io/schedule-name=velero-cluster-state -o json |
    jq -r '[.items[] | select(.status.phase == "Completed")] | sort_by(.status.completionTimestamp) | .[].metadata.name'
}
wait_for "Velero to list the backups in the store" 300 bash -c "kubectl -n velero get backups.velero.io -l velero.io/schedule-name=velero-cluster-state -o jsonpath='{.items[*].status.phase}' | grep -q Completed"
backup="$(completed_backups | tail -1)"
kubectl create -f - >/dev/null <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: $backup-early-$(date +%s)
  namespace: velero
spec:
  backupName: $backup
  includedNamespaces: [secrets-emulator, vault]
  includedResources: [secrets]
  labelSelector:
    matchLabels: { fincore.io/restore: early }
  existingResourcePolicy: none
YAML
wait_for "the Velero restore" 300 bash -c \
  "kubectl -n velero get restores.velero.io -o json | jq -e '[.items[] | select(.spec.backupName == \"$backup\")] | last | .status.phase == \"Completed\"' >/dev/null"
kubectl -n vault get secret local-kms-seed >/dev/null || die "the KMS seed was not restored"
ok "secrets restored from $backup ($(kubectl -n secrets-emulator get secrets -l fincore.io/restore=early --no-headers | wc -l | tr -d ' ') emulated Secrets Manager entries and the KMS seed)"

log "restore 2/3: Vault (newest Raft snapshot)"
snap_key="$(s3_latest vault/)"
[[ -n "$snap_key" ]] || die "no Vault snapshot in the backup store"
s3 -o "$work/vault.snap" "$snap_key"
wait_for "vault-0 to run" "$STAGE_WAIT" bash -c "[[ \$(kubectl -n vault get pod vault-0 -o jsonpath='{.status.containerStatuses[0].started}' 2>/dev/null) == true ]]"
"$ROOT/scripts/vault-init.sh" --restore "$work/vault.snap" 2>&1 | indent
echo "$snap_key" > "$ROOT/.kube/restored-from.txt"

log "restore 3/3: PostgreSQL (newest pg_dumpall)"
dump_key="$(s3_latest postgres/)"
[[ -n "$dump_key" ]] || die "no PostgreSQL dump in the backup store"
s3 -o "$work/postgres.sql.gz" "$dump_key"
wait_for "PostgreSQL" "$STAGE_WAIT" bash -c "[[ \$(kubectl -n fincore-data get pod postgres-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null) == true ]]"
# The superuser already exists in the fresh database; that is the only error expected.
errors="$(gunzip -c "$work/postgres.sql.gz" | kubectl -n fincore-data exec -i postgres-0 -- psql -U postgres -d postgres -q 2>&1 >/dev/null |
  grep ERROR | grep -v 'role "postgres" already exists' || true)"
[[ -z "$errors" ]] || { echo "$errors" | head -10; die "the PostgreSQL restore reported errors"; }
echo "$dump_key" >> "$ROOT/.kube/restored-from.txt"
rm -rf "$work"
ok "data restored from $snap_key and $dump_key"

log "releasing the restore hold: database bootstrap, Vault configuration, services, backups"
kubectl -n argocd patch application root --type merge \
  -p '{"spec":{"source":{"helm":{"parameters":[{"name":"restoreHold","value":"false"}]}}}}' >/dev/null
ok "restore stages done in $(( SECONDS - RESTORE_START ))s"
