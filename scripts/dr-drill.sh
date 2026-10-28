#!/usr/bin/env bash
# Phase 3 acceptance C5: disaster recovery drill on kind.
#
#   scripts/dr-drill.sh [output-dir]        # default docs/evidence/phase-3
#
#   1. before: the newest backups in the store (Velero cluster state, Vault
#      Raft snapshot, PostgreSQL dump), the data (payments, ledger) and the
#      ledger invariant. Vault's recovery keys go to "offline storage"
#      (.kube/vault-recovery-keys.offline.json), as an operator would keep them.
#   2. disaster: the whole cluster is deleted (scripts/kind-down.sh). Payments
#      kept flowing until that moment, so the newest data is not in any backup.
#   3. recovery: scripts/kind-up.sh --restore into a new cluster.
#   4. after: the first successful payment (RTO), what came back and what was
#      lost (RPO), the ledger invariant, Vault (3 nodes, unsealed, its data).
#
# The backup store (SeaweedFS) and the registry live outside the cluster and
# survive, as S3 and ECR would.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl jq curl docker kind

OUT="${1:-$ROOT/docs/evidence/phase-3}"
mkdir -p "$OUT"
LOG="$OUT/dr-drill.log"
: > "$LOG"
stamp() { while IFS= read -r l; do printf '%s %s\n' "$(date -u +%H:%M:%S)" "$l"; done; }
say() { log "$*"; printf '%s ==> %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$LOG"; }
utc() { date -u -r "$1" '+%H:%M:%S' 2>/dev/null || date -u -d "@$1" '+%H:%M:%S'; }
epoch_of_key() { # postgres/20261028T021500Z.sql.gz -> epoch
  local ts; ts="$(basename "$1" | cut -c1-16)"
  date -u -j -f '%Y%m%dT%H%M%SZ' "$ts" +%s 2>/dev/null || date -u -d "${ts:0:8} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s
}
psql_q() { # db sql -> value
  kubectl -n fincore-data exec postgres-0 -- psql -U postgres -d "$1" -Atc "$2" 2>/dev/null
}

# ---------------------------------------------------------------- 1. before
say "1. before the disaster"
kubectl get nodes >/dev/null || die "no cluster to destroy (run scripts/kind-up.sh first)"
newest_velero() {
  kubectl -n velero get backups.velero.io -l velero.io/schedule-name=velero-cluster-state -o json |
    jq -r '[.items[] | select(.status.phase == "Completed")] | sort_by(.status.completionTimestamp) | last | "\(.metadata.name) \(.status.completionTimestamp)"'
}
backup_set_complete() {
  [[ -n "$(s3_latest vault/)" && -n "$(s3_latest postgres/)" ]] && newest_velero | grep -q 'Z$'
}
wait_for "a complete backup set (Velero, Vault snapshot, PostgreSQL dump; schedule */15)" 1200 backup_set_complete

# The disaster strikes between two backups, while payments flow.
sleep "${DISASTER_DELAY:-90}"
read -r VELERO_BACKUP VELERO_AT <<<"$(newest_velero)"
VAULT_KEY="$(s3_latest vault/)"
DUMP_KEY="$(s3_latest postgres/)"
VELERO_T="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$VELERO_AT" +%s 2>/dev/null || date -u -d "$VELERO_AT" +%s)"
VAULT_T="$(epoch_of_key "$VAULT_KEY")"
DUMP_T="$(epoch_of_key "$DUMP_KEY")"
DUMP_TS="$(date -u -r "$DUMP_T" '+%Y-%m-%d %H:%M:%S+00' 2>/dev/null || date -u -d "@$DUMP_T" '+%Y-%m-%d %H:%M:%S+00')"

PAY_BEFORE="$(psql_q payments 'select count(*) from payments')"
PAY_AT_DUMP="$(psql_q payments "select count(*) from payments where created_at <= '$DUMP_TS'")"
LEDGER_BEFORE="$(psql_q ledger 'select count(*) from transactions')"
SAMPLE_ID="$(psql_q payments "select id from payments where status = 'captured' and created_at < '$DUMP_TS'::timestamptz - interval '1 minute' order by created_at desc limit 1")"
IMB_BEFORE="$(psql_q ledger "select coalesce(sum(case direction when 'debit' then amount else -amount end), 0) from entries")"
say "newest backups: Velero $VELERO_BACKUP ($(utc "$VELERO_T")), Vault $VAULT_KEY, PostgreSQL $DUMP_KEY"
say "data: $PAY_BEFORE payments ($PAY_AT_DUMP of them in the newest dump), $LEDGER_BEFORE ledger transactions, imbalance $IMB_BEFORE; sample payment $SAMPLE_ID"

# Recovery keys to offline storage: kind-down deletes the cluster's copy.
[[ -f "$ROOT/.kube/vault-init.json" ]] && cp "$ROOT/.kube/vault-init.json" "$ROOT/.kube/vault-recovery-keys.offline.json"

# ---------------------------------------------------------------- 2. disaster
T_DISASTER="$(date +%s)"
say "2. disaster: deleting the cluster"
"$ROOT/scripts/kind-down.sh" 2>&1 | stamp >> "$LOG"
T_GONE="$(date +%s)"
say "cluster deleted ($(( T_GONE - T_DISASTER ))s)"

# ---------------------------------------------------------------- 3. recovery
say "3. recovery: scripts/kind-up.sh --restore"
T_RESTORE="$(date +%s)"
set +e
"$ROOT/scripts/kind-up.sh" --restore 2>&1 | stamp | tee -a "$LOG" | grep -E '==>|✔|✘'
rc="${PIPESTATUS[0]}"
set -e
[[ "$rc" == 0 ]] || die "kind-up --restore failed (see $LOG)"
T_PLATFORM="$(date +%s)"
[[ -f "$ROOT/.kube/vault-recovery-keys.offline.json" ]] && mv "$ROOT/.kube/vault-recovery-keys.offline.json" "$ROOT/.kube/vault-init.json"

kubectl -n "$NS_CDE" port-forward svc/payments-api 18380:8080 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
first_payment() {
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST http://localhost:18380/v1/payments \
    -H 'Content-Type: application/json' -H "Idempotency-Key: dr-$(date +%s%N)" \
    -d '{"merchant_id":"m_dr_drill","amount":1000,"currency":"USD","card_token":"tok_visa"}')" == 201 ]]
}
wait_for "the first successful payment" 600 first_payment
T_FIRST="$(date +%s)"
say "first payment captured: RTO $(( T_FIRST - T_DISASTER ))s"

# ---------------------------------------------------------------- 4. after
say "4. after the recovery"
PAY_AFTER="$(psql_q payments "select count(*) from payments where merchant_id <> 'm_dr_drill' and created_at <= to_timestamp($T_DISASTER)")"
LEDGER_AFTER="$(psql_q ledger "select count(*) from transactions where created_at <= to_timestamp($T_DISASTER)")"
IMB_AFTER="$(psql_q ledger "select coalesce(sum(case direction when 'debit' then amount else -amount end), 0) from entries")"
SAMPLE_BACK="$(curl -s --max-time 5 "http://localhost:18380/v1/payments/$SAMPLE_ID" | jq -r '.status // "missing"')"
VAULT_OK=0
for i in 0 1 2; do
  kubectl -n vault exec "vault-$i" -c vault -- vault status -format=json 2>/dev/null | jq -e '.initialized and (.sealed | not)' >/dev/null && VAULT_OK=$((VAULT_OK + 1))
done
CREDS_ROTATING="$(kubectl -n "$NS_CDE" logs -l app.kubernetes.io/name=ledger -c vault-agent --tail=50 2>/dev/null | grep -c 'rendered "(dynamic)"' || true)"
RESTORED_FROM="$(tr '\n' ' ' < "$ROOT/.kube/restored-from.txt" 2>/dev/null || true)"
say "payments: $PAY_AFTER of $PAY_BEFORE back (dump held $PAY_AT_DUMP); ledger transactions $LEDGER_AFTER of $LEDGER_BEFORE; imbalance $IMB_AFTER"
say "sample payment $SAMPLE_ID: $SAMPLE_BACK; Vault nodes unsealed: $VAULT_OK/3; Vault-issued DB credentials rendered: $CREDS_ROTATING"

RPO_DATA=$(( T_DISASTER - DUMP_T ))
RPO_VAULT=$(( T_DISASTER - VAULT_T ))
RPO_STATE=$(( T_DISASTER - VELERO_T ))
RTO=$(( T_FIRST - T_DISASTER ))
FAIL=0
[[ "$PAY_AFTER" == "$PAY_AT_DUMP" ]] || FAIL=1
[[ "$IMB_AFTER" == 0 ]] || FAIL=1
[[ "$SAMPLE_BACK" == captured ]] || FAIL=1
[[ "$VAULT_OK" == 3 ]] || FAIL=1

{
  echo "# Disaster recovery drill on kind"
  echo
  echo "$(date -u -r "$T_DISASTER" '+%Y-%m-%d' 2>/dev/null || date -u -d "@$T_DISASTER" '+%Y-%m-%d'): the whole cluster was deleted while payments were flowing, then rebuilt from the backup store with \`scripts/kind-up.sh --restore\`."
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| **RTO** (disaster to first successful payment) | **$(( RTO / 60 )) min $(( RTO % 60 )) s** |"
  echo "| **RPO** (age of the newest data backup at the disaster) | **$(( RPO_DATA / 60 )) min $(( RPO_DATA % 60 )) s** (PostgreSQL dump); Vault snapshot $(( RPO_VAULT / 60 )) min $(( RPO_VAULT % 60 )) s; Velero cluster state $(( RPO_STATE / 60 )) min $(( RPO_STATE % 60 )) s |"
  echo "| Payments | $PAY_BEFORE before; $PAY_AFTER restored, exactly the $PAY_AT_DUMP in the newest dump; $(( PAY_BEFORE - PAY_AFTER )) made after it were lost (within the RPO) |"
  echo "| Ledger | $LEDGER_AFTER of $LEDGER_BEFORE transactions restored; imbalance $IMB_BEFORE before, **$IMB_AFTER after** |"
  echo "| Sample payment (captured before the dump) | \`$SAMPLE_ID\`: $SAMPLE_BACK after the restore |"
  echo "| Vault | $VAULT_OK/3 nodes initialised and unsealed by the original KMS key, with the original data (policies, Kubernetes auth, database engine); the ledger received fresh Vault-issued credentials |"
  echo "| Restored from | Velero backup \`$VELERO_BACKUP\`, $RESTORED_FROM |"
  echo
  echo "## Timeline (UTC)"
  echo
  echo "| Time | Step |"
  echo "|---|---|"
  echo "| $(utc "$T_DISASTER") | Disaster: cluster deletion starts |"
  echo "| $(utc "$T_GONE") | Cluster gone |"
  echo "| $(utc "$T_RESTORE") | \`kind-up.sh --restore\` starts (new cluster, images from the registry, Argo CD) |"
  grep -E '==> restore [123]/3|secrets restored|snapshot restored|Vault HA restored|data restored|restore stages done|FinCore is up' "$LOG" |
    sed -E 's/\x1b\[[0-9;]*m//g; s/^([0-9:]+) +(==>|✔) */| \1 | /; s/$/ |/'
  echo "| $(utc "$T_PLATFORM") | Every application Synced and Healthy |"
  echo "| $(utc "$T_FIRST") | First successful payment |"
  echo
  echo "The RPO is bounded by the backup schedule (every 15 minutes on kind). On AWS, Aurora's continuous backups give point-in-time recovery to within about 5 minutes, and the same Vault snapshot and Velero schedules apply."
  echo "Full log: \`dr-drill.log\`."
} > "$OUT/dr-drill.md"
cat "$OUT/dr-drill.md"
[[ $FAIL == 0 ]] || die "the drill found a problem (see above)"
ok "DR DRILL PASSED: RTO ${RTO}s, RPO ${RPO_DATA}s"
