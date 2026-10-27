#!/usr/bin/env bash
# Phase 2 acceptance B2: the ledger's database password rotates without a restart.
#
# The ledger has no static database password. Each pod's Vault Agent obtains a
# short-lived PostgreSQL user (database/creds/ledger, TTL 3 minutes on kind),
# renders it to /vault/secrets/db.json and renders a new one before it expires;
# the ledger re-reads the file for every new connection. Vault revokes (drops)
# the old user when its lease ends.
#
# Asserted while the traffic generator keeps sending payments:
#   - every ledger pod switches to a new Vault-issued user, and the old users are
#     dropped from PostgreSQL;
#   - the same pods keep running: no restart, no replacement;
#   - zero 5xx from the ledger and payments-api during the whole window.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl jq curl yq

TTL="$(yq -r '.databaseRoles.ledger.defaultTTL' "$ROOT/gitops/platform/vault-config/values.yaml")"
psql_() { kubectl -n fincore-data exec postgres-0 -c postgres -- psql -U postgres -At -F ' ' -c "$1"; }
pods_json() { kubectl -n "$NS_CDE" get pods -l app.kubernetes.io/name=ledger -o json; }

log "ledger pods (TTL of Vault-issued database users: $TTL)"
P0="$(pods_json)"
NPODS="$(jq '[.items[] | select(.status.phase == "Running")] | length' <<<"$P0")"
[[ "$NPODS" -ge 1 ]] || die "no running ledger pods"
jq -r '.items[] | "   \(.metadata.name)  containers=\([.spec.containers[].name] | join(","))  restarts=\([.status.containerStatuses[].restartCount] | add)"' <<<"$P0"
jq -e '[.items[].spec.containers[].name] | index("vault-agent")' <<<"$P0" >/dev/null || die "ledger pods have no vault-agent sidecar"
NAMES0="$(jq -r '[.items[].metadata.name] | sort | join(" ")' <<<"$P0")"
RESTARTS0="$(jq '[.items[].status.containerStatuses[].restartCount] | add' <<<"$P0")"
kubectl -n "$NS_CDE" get deploy,rollout -l app.kubernetes.io/name=ledger -o name 2>/dev/null | sed 's/^/   /' || true
echo "   static ledger password in the cluster: $(kubectl -n "$NS_CDE" get secret ledger-db -o name 2>/dev/null || echo none)"
echo "   ledger owner role can log in: $(psql_ "select rolcanlogin from pg_roles where rolname = 'ledger'")"

log "watching PostgreSQL while the traffic generator keeps posting payments"
T0=$SECONDS
START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
declare -a SEEN=()
REVOKED=0
last=""
while :; do
  active="$(psql_ "select usename, count(*) from pg_stat_activity where datname = 'ledger' and usename like 'v-%' group by usename order by 1")"
  roles="$(psql_ "select rolname from pg_roles where rolname like 'v-%ledger%' order by 1")"
  while read -r u _; do
    [[ -z "$u" || " ${SEEN[*]+${SEEN[*]}} " == *" $u "* ]] || SEEN+=("$u")
  done <<<"$active"
  REVOKED=0
  for u in ${SEEN[@]+"${SEEN[@]}"}; do
    grep -qx "$u" <<<"$roles" || REVOKED=$((REVOKED + 1))
  done
  snapshot="$(awk '{printf "%s(%s conns) ", $1, $2}' <<<"$active")"
  if [[ "$snapshot" != "$last" ]]; then
    printf '   [%3ss] connected as: %s| users in pg_roles: %s | revoked so far: %s\n' \
      "$(( SECONDS - T0 ))" "$snapshot" "$(wc -l <<<"$roles" | tr -d ' ')" "$REVOKED"
    last="$snapshot"
  fi
  (( REVOKED >= NPODS )) && break
  (( SECONDS - T0 > 900 )) && die "no complete rotation observed within 15 minutes"
  sleep 5
done
WINDOW=$(( SECONDS - T0 + 30 ))
ok "every pod moved to a new Vault-issued user and $REVOKED expired user(s) were dropped ($(( SECONDS - T0 ))s)"

log "the same pods kept running"
P1="$(pods_json)"
NAMES1="$(jq -r '[.items[].metadata.name] | sort | join(" ")' <<<"$P1")"
RESTARTS1="$(jq '[.items[].status.containerStatuses[].restartCount] | add' <<<"$P1")"
echo "   pods before: $NAMES0 (restarts $RESTARTS0)"
echo "   pods after:  $NAMES1 (restarts $RESTARTS1)"
[[ "$NAMES0" == "$NAMES1" && "$RESTARTS0" == "$RESTARTS1" ]] || die "ledger pods were restarted or replaced"
ok "no restart, no replacement"
for p in $NAMES1; do
  kubectl -n "$NS_CDE" logs "$p" -c app --since-time="$START_TS" | grep 'database credentials rotated' | tail -1 \
    | jq -r --arg p "$p" '"   \($p): \(.msg): \(.previous_db_user) -> \(.db_user)"' || true
done

log "no errors during the rotation (Prometheus, last ${WINDOW}s)"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT
wait_for "prometheus port-forward" 30 curl -sf http://localhost:19090/-/ready
sleep 20   # one more scrape after the last rotation
promq() { curl -sG http://localhost:19090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "0"'; }
FAILED=0
for app in ledger payments-api; do
  total="$(promq "sum(increase(http_requests_total{namespace=\"$NS_CDE\",app=\"$app\",route!~\"GET /(healthz|readyz)\"}[${WINDOW}s]))")"
  errors="$(promq "sum(increase(http_requests_total{namespace=\"$NS_CDE\",app=\"$app\",code=~\"5..\"}[${WINDOW}s]))")"
  printf '   %-13s requests=%.0f  5xx=%.0f\n' "$app" "$total" "$errors"
  if awk -v t="$total" -v e="$errors" 'BEGIN { exit !(t > 0 && e == 0) }'; then :; else FAILED=1; fi
done
changes="$(promq "sum(increase(fincore_db_credential_changes_total{namespace=\"$NS_CDE\",app=\"ledger\"}[${WINDOW}s]))")"
printf '   fincore_db_credential_changes_total increase: %.0f\n' "$changes"
[[ $FAILED == 0 ]] || die "requests failed during the rotation (or no traffic was measured)"
ok "traffic flowed and nothing failed"

log "Vault audit log: credentials issued to the ledger during the window"
for v in vault-0 vault-1 vault-2; do
  kubectl -n vault logs "$v" -c vault --since-time="$START_TS" 2>/dev/null \
    | grep '"type":"response"' | grep '"path":"database/creds/ledger"' || true
done | jq -r '"   \(.time)  \(.auth.metadata.service_account_namespace // "?")/\(.auth.metadata.service_account_name // "?")  read \(.request.path)  lease \(.response.secret.lease_id // "-" | split("/") | last)"' | head -10

echo
ok "DEMO PASSED: the ledger's database credentials rotated under load without a restart"
