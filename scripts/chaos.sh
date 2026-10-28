#!/usr/bin/env bash
# Phase 3 acceptance C4: chaos experiments on kind, with their SLO impact.
#
#   scripts/chaos.sh [output-dir]                      # default docs/evidence/phase-3
#   EXPERIMENTS="pod-kill db-restart" scripts/chaos.sh /tmp/chaos
#
# Experiments, in order (each: 60 s baseline, fault, recovery, 120 s after):
#   pod-kill    one payments-api and one ledger pod killed without grace
#   node-drain  zone a's worker drained as for maintenance (PDBs respected,
#               180 s timeout), then uncordoned
#   db-restart  PostgreSQL restarted (on AWS: an Aurora failover, scripts/chaos-aws.sh)
#   zone-loss   zone c (the CDE) lost abruptly: its node is frozen for
#               ZONE_LOSS_SECONDS (docker pause), then comes back
#
# Each experiment is measured three ways:
#   client   a k6 probe (5 req/s, every result logged) sees what callers see
#   server   Prometheus: requests, 5xx and p99 as payments-api counts them
#   alerts   Alertmanager's API, polled every 15 s: what fired, when, to which receiver
# and the invariants are checked after it: the ledger balances and the outbox drains.
# Before the first experiment no page may be firing (so every page is caused by
# an experiment); at the end the script waits for every page to resolve (up to
# RESOLVE_WAIT s). Tickets are slow-burn alerts by design (2 h and 6 h short
# windows): they are reported, not waited for.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl jq yq docker curl

OUT="${1:-$ROOT/docs/evidence/phase-3}"
EXPERIMENTS="${EXPERIMENTS:-pod-kill node-drain db-restart zone-loss}"
ZONE_LOSS_SECONDS="${ZONE_LOSS_SECONDS:-240}"
RESOLVE_WAIT="${RESOLVE_WAIT:-2700}"
CLEAN_WAIT="${CLEAN_WAIT:-2700}"
PROBE_RATE=5
mkdir -p "$OUT"
RUN="$(date +%s)"
PROBE="chaos-probe-$RUN"
IMAGE="$(yq -r .image "$ROOT/gitops/apps/traffic-generator/values.yaml")"
TARGET="$(yq -r .target "$ROOT/gitops/apps/traffic-generator/values.yaml")"
WORK="$(mktemp -d)"
ALERTS_RAW="$WORK/alerts.raw"
PIDS=()

PROM=/api/v1/namespaces/monitoring/services/http:prometheus-operated:9090/proxy/api/v1
AM=/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-alertmanager:9093/proxy/api/v2
promq() { # query unix-time -> value or NaN
  kubectl get --raw "$PROM/query?query=$(jq -rn --arg v "$1" '$v|@uri')&time=$2" 2>/dev/null |
    jq -r '.data.result[0].value[1] // "NaN"'
}
utc() { date -u -r "$1" '+%H:%M:%S' 2>/dev/null || date -u -d "@$1" '+%H:%M:%S'; }
PAY='app="payments-api",route="POST /v1/payments"'

cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
  docker unpause fincore-worker3 >/dev/null 2>&1 || true
  kubectl uncordon fincore-worker >/dev/null 2>&1 || true
  kubectl -n "$NS_APP" delete job "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$NS_APP" delete configmap "$PROBE" --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- start clean
pages_active() {
  kubectl get --raw "$AM/alerts?active=true&silenced=false&inhibited=false" 2>/dev/null |
    jq '[.[] | select(.labels.severity == "page")] | length'
}
log "waiting until no page is firing (up to ${CLEAN_WAIT}s), so every page below comes from an experiment"
t=$SECONDS
until [[ "$(pages_active)" == 0 ]] || (( SECONDS - t > CLEAN_WAIT )); do sleep 30; done
[[ "$(pages_active)" == 0 ]] || die "pages still firing after ${CLEAN_WAIT}s; not starting"
ok "no page firing ($(( SECONDS - t ))s)"

# ---------------------------------------------------------------- client probe
cat > "$WORK/probe.js" <<'JS'
// One line per request: P <epoch ms> <status> <duration ms>. Status 0 = no answer.
import http from 'k6/http';
export const options = {
  noConnectionReuse: true,
  scenarios: { probe: { executor: 'constant-arrival-rate', rate: Number(__ENV.RATE), timeUnit: '1s',
                        duration: '4h', preAllocatedVUs: 20, maxVUs: 60 } },
};
export default function () {
  const t = Date.now();
  const res = http.post(`${__ENV.TARGET}/v1/payments`, JSON.stringify({
    merchant_id: 'm_chaos_probe', amount: 500, currency: 'USD', card_token: 'tok_visa' }), {
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': `probe-${__VU}-${__ITER}-${t}` },
    timeout: '5s' });
  console.log(`P ${t} ${res.status} ${Math.round(res.timings.duration)}`);
}
JS
kubectl -n "$NS_APP" create configmap "$PROBE" --from-file=probe.js="$WORK/probe.js" >/dev/null
kubectl -n "$NS_APP" create -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $PROBE
  labels: { app.kubernetes.io/name: loadtest, app.kubernetes.io/part-of: fincore }
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: { app.kubernetes.io/name: loadtest, app.kubernetes.io/part-of: fincore }
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      # Off the nodes the experiments disturb, so the probe itself survives them.
      nodeSelector: { kubernetes.io/hostname: fincore-worker2 }
      securityContext:
        runAsNonRoot: true
        runAsUser: 12345
        runAsGroup: 12345
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: k6
          image: $IMAGE
          args: ["run", "--quiet", "--log-format=raw", "--summary-mode=disabled", "/scripts/probe.js"]
          env:
            - { name: TARGET, value: "$TARGET" }
            - { name: RATE, value: "$PROBE_RATE" }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { memory: 256Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: scripts, mountPath: /scripts }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: scripts
          configMap: { name: $PROBE }
        - name: tmp
          emptyDir: {}
EOF
wait_for "the client probe to run" 180 bash -c \
  "kubectl -n $NS_APP logs job/$PROBE 2>/dev/null | grep -q '^P '"
ok "client probe running ($PROBE_RATE req/s from fincore-worker2)"

# ---------------------------------------------------------------- alert watcher
(
  while true; do
    now="$(date +%s)"
    kubectl get --raw "$AM/alerts?active=true&silenced=false&inhibited=true" 2>/dev/null |
      jq -r --arg now "$now" '.[] | select(.labels.alertname != "Watchdog" and .labels.alertname != "InfoInhibitor")
        | "\($now)\t\(.labels.alertname)\t\(.labels.severity // "-")\t\(.status.state)\t\([.receivers[].name] | join(","))\t\(.startsAt)"' || true
    sleep 15
  done
) >> "$ALERTS_RAW" &
PIDS+=($!)

probe_lines() { kubectl -n "$NS_APP" logs "job/$PROBE" 2>/dev/null | awk '$1 == "P"'; }
# client_stats <from> <to> -> JSON {requests, failed, availability, longest_outage_s, p99_ms}
client_stats() {
  local lines p99
  lines="$(probe_lines | awk -v a="$(( $1 * 1000 ))" -v b="$(( $2 * 1000 ))" '$2 >= a && $2 <= b')"
  p99="$(awk '{print $4}' <<<"$lines" | sort -n | awk '{d[NR] = $1} END {i = int(NR * 0.99); if (i < NR * 0.99) i++; print (NR ? d[i] : 0)}')"
  awk -v p99="$p99" '
    { n++
      # An outage runs from the first failed request to the next answered one.
      if ($3 == 0 || $3 >= 500) { f++; if (!s) s = $2; e = $2 } else { if (s && $2 - s > m) m = $2 - s; s = 0 } }
    END {
      if (s && e - s > m) m = e - s
      printf "{\"requests\":%d,\"failed\":%d,\"availability\":%.5f,\"longest_outage_s\":%.1f,\"p99_ms\":%d}\n",
        n, f, (n ? 1 - f / n : 1), m / 1000, p99
    }' <<<"$lines"
}

# ---------------------------------------------------------------- invariants
ledger_balanced() { # fresh port-forward each time: a pod behind an old one may be gone
  local pf rc=0
  kubectl -n "$NS_CDE" port-forward svc/ledger 18281:8080 >/dev/null 2>&1 &
  pf=$!
  for _ in $(seq 1 10); do curl -sf --max-time 3 http://localhost:18281/readyz >/dev/null 2>&1 && break; sleep 2; done
  curl -sf --max-time 3 http://localhost:18281/readyz >/dev/null 2>&1 || rc=1
  [[ $rc == 0 ]] && { curl -sf --max-time 5 http://localhost:18281/v1/invariants | jq -e '.balanced == true' >/dev/null || rc=1; }
  kill "$pf" 2>/dev/null || true
  wait "$pf" 2>/dev/null || true
  return $rc
}
outbox_drained() { [[ "$(promq 'max(outbox_backlog_events)' "$(date +%s)")" == 0 ]]; }

# ---------------------------------------------------------------- experiments
RESULTS="[]"
NOTES=""
note() { NOTES+="$*"$'\n'; echo "   $*"; }

wait_cde_ready() { # all payments-api and ledger replicas available again
  local r
  for r in payments-api ledger; do
    wait_for "$r to be fully available" 600 bash -c \
      "[[ \$(kubectl -n $NS_CDE get rollout $r -o jsonpath='{.status.availableReplicas}') -ge \$(kubectl -n $NS_CDE get rollout $r -o jsonpath='{.spec.replicas}') ]]"
  done
}

inject_pod-kill() {
  local p l
  p="$(kubectl -n "$NS_CDE" get pods -l app.kubernetes.io/name=payments-api -o name | head -1)"
  l="$(kubectl -n "$NS_CDE" get pods -l app.kubernetes.io/name=ledger -o name | head -1)"
  note "killed ${p#pod/} and ${l#pod/} (no grace period)"
  kubectl -n "$NS_CDE" delete "$p" "$l" --grace-period=0 --force >/dev/null 2>&1
  T_FAULT_END="$(date +%s)"
  wait_cde_ready
}

inject_node-drain() {
  local out rc=0
  out="$(kubectl drain fincore-worker --ignore-daemonsets --delete-emptydir-data --timeout=180s 2>&1)" || rc=$?
  note "drained fincore-worker (zone a): $(grep -c 'evicted$' <<<"$out" || true) pods evicted, drain exit code $rc"
  grep -E "Cannot evict|error when evicting" <<<"$out" | sed 's/^.*evicting pods\/"\([^"]*\)" -n "\([^"]*\)".*$/blocked by its PodDisruptionBudget: \2\/\1/' | sort -u |
    while IFS= read -r l; do note "$l"; done
  local pending
  pending="$(kubectl get pods -A --field-selector=status.phase=Pending -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}')"
  [[ -n "$pending" ]] && note "pending while the node was cordoned: $pending"
  sleep 30
  kubectl uncordon fincore-worker >/dev/null
  T_FAULT_END="$(date +%s)"
  note "uncordoned after $(( T_FAULT_END - T_FAULT ))s"
  wait_for "all pods to run again" 600 bash -c \
    "! kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | grep -q ."
  wait_for "Vault to have 3 unsealed members" 600 bash -c \
    "for i in 0 1 2; do kubectl -n vault exec vault-\$i -c vault -- vault status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null || exit 1; done"
  wait_cde_ready
}

inject_db-restart() {
  kubectl -n fincore-data delete pod postgres-0 >/dev/null
  wait_for "PostgreSQL to be ready" 300 bash -c \
    "[[ \$(kubectl -n fincore-data get pod postgres-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null) == true ]]"
  T_FAULT_END="$(date +%s)"
  note "postgres-0 deleted and ready again after $(( T_FAULT_END - T_FAULT ))s"
}

inject_zone-loss() {
  docker pause fincore-worker3 >/dev/null
  note "zone c frozen (docker pause fincore-worker3: payments-api and ledger, the whole CDE) for ${ZONE_LOSS_SECONDS}s"
  local t=$SECONDS
  until (( SECONDS - t >= ZONE_LOSS_SECONDS )); do sleep 5; done
  docker unpause fincore-worker3 >/dev/null
  T_FAULT_END="$(date +%s)"
  wait_for "fincore-worker3 to be Ready" 300 bash -c \
    "kubectl get node fincore-worker3 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
  wait_cde_ready
  note "zone c back; CDE ready $(( $(date +%s) - T_FAULT_END ))s after the node returned"
}

for exp in $EXPERIMENTS; do
  declare -F "inject_$exp" >/dev/null || die "unknown experiment: $exp"
  echo
  log "experiment: $exp"
  NOTES=""
  sleep 60                                     # baseline
  T_FAULT="$(date +%s)"
  "inject_$exp"
  T_RECOVERED="$(date +%s)"
  sleep 120                                    # after
  T_END="$(date +%s)"
  from=$(( T_FAULT - 10 )); win=$(( T_END - from ))

  client="$(client_stats "$from" "$T_END")"
  srv_req="$(promq "sum(increase(http_requests_total{$PAY}[${win}s]))" "$T_END")"
  srv_5xx="$(promq "sum(increase(http_requests_total{$PAY,code=~\"5..\"}[${win}s])) or vector(0)" "$T_END")"
  srv_p99="$(promq "max_over_time(histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{$PAY}[1m])))[${win}s:15s])" "$T_END")"
  base_rps="$(promq "sum(rate(http_requests_total{$PAY}[1m]))" "$T_FAULT")"
  published="$(promq "sum(increase(outbox_events_published_total[${win}s]))" "$T_END")"
  received="$(promq "sum(increase(events_received_total[${win}s]))" "$T_END")"
  balanced=false; ledger_balanced && balanced=true
  drained=false
  t=$SECONDS; until outbox_drained || (( SECONDS - t > 180 )); do sleep 5; done
  outbox_drained && drained=true

  echo "   client: $client"
  echo "   server: requests $(printf '%.0f' "$srv_req"), 5xx $(printf '%.0f' "$srv_5xx"), max p99 $(printf '%.3f' "$srv_p99") s"
  echo "   ledger balanced: $balanced, outbox drained: $drained"
  RESULTS="$(jq -c --arg exp "$exp" --argjson fault "$T_FAULT" --argjson fend "$T_FAULT_END" \
    --argjson rec "$T_RECOVERED" --argjson end "$T_END" --argjson client "$client" \
    --arg req "$srv_req" --arg e5 "$srv_5xx" --arg p99 "$srv_p99" --arg base "$base_rps" \
    --arg pub "$published" --arg rcv "$received" --argjson bal "$balanced" --argjson dr "$drained" \
    --arg notes "$NOTES" '
    def n: if . == "NaN" then null else tonumber end;
    . + [{experiment: $exp, fault_at: $fault, fault_ended_at: $fend, recovered_at: $rec, ended_at: $end,
          window_s: ($end - $fault + 10), client: $client,
          server: {requests: ($req|n), errors_5xx: ($e5|n), max_p99_s: ($p99|n), baseline_rps: ($base|n)},
          # Share of the 30-day error budget (0.1 %) this window consumed, if every
          # caller saw what the probe saw.
          budget_burned_pct: ((1 - $client.availability) * ($end - $fault + 10) / (0.001 * 2592000) * 100),
          events: {published: ($pub|n), received_by_notifier: ($rcv|n)},
          ledger_balanced: $bal, outbox_drained: $dr,
          notes: ($notes | split("\n") | map(select(. != "")))}]' <<<"$RESULTS")"
done

# ---------------------------------------------------------------- wait for alerts to resolve
echo
log "waiting for every page to resolve (up to ${RESOLVE_WAIT}s; the 6h/30m page pair holds for ~30 min after an outage)"
t=$SECONDS
until [[ "$(pages_active)" == 0 ]] || (( SECONDS - t > RESOLVE_WAIT )); do sleep 30; done
T_DONE="$(date +%s)"
sleep 20
STILL="$(pages_active)"
TICKETS="$(kubectl get --raw "$AM/alerts?active=true" 2>/dev/null | jq -r '[.[] | select(.labels.severity == "ticket") | .labels.alertname] | unique | join(", ")')"

# Alert timeline: first and last time each alert was seen active, with its receivers.
TIMELINE="$(sort -n "$ALERTS_RAW" | awk -F'\t' '
  { k = $2 "\t" $3; if (!(k in first)) { first[k] = $1; order[++n] = k }; last[k] = $1
    if ($4 == "active") { fired[k] = 1; if (!(k in factive)) factive[k] = $1; rcv[k] = $5 }
    if ($4 == "suppressed") supp[k] = 1 }
  END { for (i = 1; i <= n; i++) { k = order[i]
          printf "%s\t%s\t%s\t%s\t%s\t%s\n", k, first[k], (k in factive ? factive[k] : "-"), last[k], (k in rcv ? rcv[k] : "-"), (k in supp ? "inhibited at times" : "") } }')"

{
  echo "# Chaos experiments on kind"
  echo
  echo "Run $(date -u -r "$RUN" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date -u -d "@$RUN" '+%Y-%m-%d %H:%M UTC'). Each experiment: 60 s baseline, the fault, recovery, then 120 s; the measurement window runs from 10 s before the fault to the end of those 120 s."
  echo "Client = a k6 probe sending $PROBE_RATE payments/s from a node the experiments do not touch (status 0 = no answer within 5 s)."
  echo "Server = payments-api's own metrics in Prometheus. Budget = share of the 30-day 0.1 % error budget the window consumed, at the probe's failure rate."
  echo
  echo "| Experiment | Fault | Client availability | Longest client-visible outage | Client p99 | Server 5xx / requests | Server max p99 | Budget burned | Ledger balanced | Outbox drained |"
  echo "|---|---|---:|---:|---:|---:|---:|---:|:---:|:---:|"
  jq -r '.[] | "| \(.experiment) | \(.fault_ended_at - .fault_at) s | \(.client.availability * 100 | . * 100 | round / 100) % | \(.client.longest_outage_s) s | \(.client.p99_ms) ms | \((.server.errors_5xx // 0) | round) / \((.server.requests // 0) | round) | \(((.server.max_p99_s // 0) * 1000) | round) ms | \(.budget_burned_pct | . * 100 | round / 100) % | \(if .ledger_balanced then "yes" else "**no**" end) | \(if .outbox_drained then "yes" else "**no**" end) |"' <<<"$RESULTS"
  echo
  echo "## What happened"
  jq -r '.[] | "\n**\(.experiment)** (\(.fault_at | strftime("%H:%M:%S")) UTC): \(.notes | join("; ")). Outbox events published in the window: \((.events.published // 0) | round), received by the notifier: \((.events.received_by_notifier // 0) | round)."' <<<"$RESULTS"
  echo
  echo "## Alerts"
  echo
  if [[ -z "$TIMELINE" ]]; then
    echo "No alert fired."
  else
    echo "| Alert | Severity | First seen | Firing from | Last seen | Receiver | |"
    echo "|---|---|---|---|---|---|---|"
    while IFS=$'\t' read -r name sev first act last rcv supp; do
      a="-"; [[ "$act" != - ]] && a="$(utc "$act")"
      echo "| $name | $sev | $(utc "$first") | $a | $(utc "$last") | $rcv | $supp |"
    done <<<"$TIMELINE"
  fi
  echo
  if [[ "$STILL" == 0 ]]; then
    echo "Every page resolved by $(utc "$T_DONE") UTC."
  else
    echo "**$STILL page(s) still firing after waiting ${RESOLVE_WAIT}s.**"
  fi
  [[ -n "$TICKETS" ]] && echo "Tickets still open at the end (slow-burn by design, 2 h / 6 h short windows): $TICKETS."
  echo
  echo "Experiment times (UTC): $(jq -r '[.[] | "\(.experiment) \(.fault_at | strftime("%H:%M:%S"))-\(.recovered_at | strftime("%H:%M:%S"))"] | join(", ")' <<<"$RESULTS")."
  echo "Files: \`chaos-results.json\`, \`chaos-alerts.tsv\` (every Alertmanager poll), \`chaos-probe.log\` (every probe request)."
} > "$OUT/chaos.md"
jq . <<<"$RESULTS" > "$OUT/chaos-results.json"
{ printf 'polled_at\talertname\tseverity\tstate\treceivers\tstarts_at\n'; sort -n "$ALERTS_RAW"; } > "$OUT/chaos-alerts.tsv"
probe_lines > "$OUT/chaos-probe.log"
cat "$OUT/chaos.md"
echo
FAILED_INV="$(jq '[.[] | select((.ledger_balanced and .outbox_drained) | not)] | length' <<<"$RESULTS")"
[[ "$FAILED_INV" == 0 ]] || die "$FAILED_INV experiment(s) broke an invariant"
[[ "$STILL" == 0 ]] || die "pages did not resolve"
ok "CHAOS DONE: every experiment recovered, the ledger stayed balanced, every page resolved"
