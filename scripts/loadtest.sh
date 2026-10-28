#!/usr/bin/env bash
# Phase 3 acceptance C3: capacity test. k6 runs in the cluster (a port-forward
# would be the bottleneck) and steps the offered rate up; each step is then
# measured server-side from Prometheus and judged against the payments SLOs.
#
#   scripts/loadtest.sh [output-dir]          # default docs/evidence/phase-3
#   STEPS=50,100,150,200,250,300 HOLD=2m scripts/loadtest.sh
#
# A step is "within SLO" when, over its hold (first 30 s excluded):
#   p99 <= 300 ms, 5xx <= 0.1 %, and the rate served >= 95 % of the rate offered.
# The report states the highest step that held; if 300 RPS does not, that is
# the published result. Nothing here relaxes a threshold.
#
# The Job runs in "fincore" with the label app.kubernetes.io/name=loadtest,
# which the CDE NetworkPolicy admits to payments-api, and uses the same
# approved, digest-pinned k6 image as the traffic generator.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl jq yq

OUT="${1:-$ROOT/docs/evidence/phase-3}"
STEPS="${STEPS:-50,100,150,200,250,300}"
HOLD="${HOLD:-2m}"
MAX_VUS="${MAX_VUS:-300}"
RAMP=20
hold_s() { local h="$1"; case "$h" in *m) echo $(( ${h%m} * 60 ));; *s) echo "${h%s}";; *) echo "$h";; esac; }
HOLD_S="$(hold_s "$HOLD")"
SETTLE=30                      # seconds of each hold left out of the measurement
WINDOW=$(( HOLD_S - SETTLE ))
(( WINDOW >= 30 )) || die "HOLD must be at least 60s"

RUN="$(date +%s)"
JOB="loadtest-$RUN"
IMAGE="$(yq -r .image "$ROOT/gitops/apps/traffic-generator/values.yaml")"
TARGET="$(yq -r .target "$ROOT/gitops/apps/traffic-generator/values.yaml")"
mkdir -p "$OUT"

PROM=/api/v1/namespaces/monitoring/services/http:prometheus-operated:9090/proxy/api/v1
promq() { # query unix-time -> first value or "NaN"
  kubectl get --raw "$PROM/query?query=$(jq -rn --arg v "$1" '$v|@uri')&time=$2" |
    jq -r '.data.result[0].value[1] // "NaN"'
}

PAY='app="payments-api",route="POST /v1/payments"'
BASELINE="$(promq "sum(rate(http_requests_total{$PAY}[1m]))" "$(date +%s)")"
log "background traffic before the test: $(printf '%.1f' "$BASELINE") payments/s (traffic generator)"

log "k6 Job $JOB: steps $STEPS RPS, ${RAMP}s ramp + $HOLD hold each, max $MAX_VUS VUs"
kubectl -n "$NS_APP" create configmap "$JOB" --from-file=payments.js="$ROOT/loadtest/payments.js" >/dev/null
kubectl -n "$NS_APP" create -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  labels: { app.kubernetes.io/name: loadtest, app.kubernetes.io/part-of: fincore }
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: { app.kubernetes.io/name: loadtest, app.kubernetes.io/part-of: fincore }
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 12345
        runAsGroup: 12345
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: k6
          image: $IMAGE
          args: ["run", "--quiet", "/scripts/payments.js"]
          env:
            - { name: TARGET, value: "$TARGET" }
            - { name: STEPS, value: "$STEPS" }
            - { name: HOLD, value: "$HOLD" }
            - { name: MAX_VUS, value: "$MAX_VUS" }
          resources:
            requests: { cpu: 250m, memory: 128Mi }
            limits: { memory: 768Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: scripts, mountPath: /scripts }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: scripts
          configMap: { name: $JOB }
        - name: tmp
          emptyDir: {}
EOF
cleanup() { # never leave load running behind a failed script
  kubectl -n "$NS_APP" delete job "$JOB" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$NS_APP" delete configmap "$JOB" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for "k6 to start" 180 bash -c \
  "kubectl -n $NS_APP get pods -l job-name=$JOB -o jsonpath='{.items[0].status.containerStatuses[0].state.running.startedAt}' 2>/dev/null | grep -q T"
STARTED="$(kubectl -n "$NS_APP" get pods -l "job-name=$JOB" -o jsonpath='{.items[0].status.containerStatuses[0].state.running.startedAt}')"
T0=$(( $(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$STARTED" +%s 2>/dev/null || date -u -d "$STARTED" +%s) + 2 ))
IFS=, read -r -a STEP_LIST <<<"$STEPS"
TOTAL=$(( ${#STEP_LIST[@]} * (RAMP + HOLD_S) + 10 ))
log "running for about $(( TOTAL / 60 )) min (started $STARTED)"

job_done() { [[ "$(kubectl -n "$NS_APP" get job "$JOB" -o jsonpath='{.status.succeeded}{.status.failed}')" =~ [1-9] ]]; }
wait_for "the k6 Job to finish" $(( TOTAL + 300 )) job_done
LOGS="$(kubectl -n "$NS_APP" logs "job/$JOB" 2>&1 || true)"
SUMMARY="$(awk '/===K6-SUMMARY===/{f=1; next} /===END===/{f=0} f' <<<"$LOGS")"
[[ -n "$SUMMARY" ]] || { echo "$LOGS" | tail -20; die "no k6 summary in the Job's log"; }
jq . <<<"$SUMMARY" > "$OUT/loadtest-k6-summary.json"
T_END=$(( T0 + TOTAL ))
sleep 20   # let Prometheus scrape the last interval

log "measuring each step in Prometheus (window: last ${WINDOW}s of each hold)"
W="${WINDOW}s"
ready() { echo "max_over_time((count(kube_pod_status_ready{namespace=\"$NS_CDE\",condition=\"true\",pod=~\"$1-.*\"} == 1))[$W:15s])"; }
cpu() { echo "sum(rate(container_cpu_usage_seconds_total{container!=\"\",pod=~\"$1\"}[$W]))"; }
ROWS="[]"
i=0
for step in "${STEP_LIST[@]}"; do
  at=$(( T0 + (i + 1) * (RAMP + HOLD_S) ))
  served="$(promq "sum(rate(http_requests_total{$PAY}[$W]))" "$at")"
  err="$(promq "(sum(rate(http_requests_total{$PAY,code=~\"5..\"}[$W])) or vector(0)) / sum(rate(http_requests_total{$PAY}[$W]))" "$at")"
  q() { promq "histogram_quantile($1, sum by (le) (rate(http_request_duration_seconds_bucket{$PAY}[$W])))" "$at"; }
  p50="$(q 0.5)"; p95="$(q 0.95)"; p99="$(q 0.99)"
  pay_r="$(promq "$(ready payments-api)" "$at")"; led_r="$(promq "$(ready ledger)" "$at")"
  cpu_pay="$(promq "$(cpu 'payments-api-.*')" "$at")"; cpu_led="$(promq "$(cpu 'ledger-.*')" "$at")"
  cpu_pg="$(promq "$(cpu 'postgres-0')" "$at")"
  cpu_all="$(promq "sum(rate(container_cpu_usage_seconds_total{container!=\"\"}[$W]))" "$at")"
  ROWS="$(jq -c --argjson step "$step" --arg base "$BASELINE" --arg served "$served" --arg err "$err" \
    --arg p50 "$p50" --arg p95 "$p95" --arg p99 "$p99" --arg pay "$pay_r" --arg led "$led_r" \
    --arg cpay "$cpu_pay" --arg cled "$cpu_led" --arg cpg "$cpu_pg" --arg call "$cpu_all" '
    def n: if . == "NaN" then null else tonumber end;
    . + [{step: $step, offered: ($step + ($base|n)), served: ($served|n), error_ratio: ($err|n),
          p50_ms: ((($p50|n) // 0) * 1000), p95_ms: ((($p95|n) // 0) * 1000), p99_ms: ((($p99|n) // 0) * 1000),
          payments_api_pods: ($pay|n), ledger_pods: ($led|n),
          cpu_payments_api: ($cpay|n), cpu_ledger: ($cled|n), cpu_postgres: ($cpg|n), cpu_cluster: ($call|n)}
         | .within_slo = (.served != null and .p99_ms <= 300 and (.error_ratio // 0) <= 0.001
                          and .served >= 0.95 * .offered)]' <<<"$ROWS")"
  i=$(( i + 1 ))
done
jq . <<<"$ROWS" > "$OUT/loadtest-steps.json"

# Time series every 15 s over the whole test, for the report's charts.
range() { # query -> "t,value" lines
  kubectl get --raw "$PROM/query_range?query=$(jq -rn --arg v "$1" '$v|@uri')&start=$T0&end=$T_END&step=15" |
    jq -r '.data.result[0].values[]? | "\(.[0]),\(.[1])"'
}
{
  echo "t_seconds,served_rps,p95_ms,p99_ms,error_ratio,payments_api_pods,ledger_pods"
  join -t, <(range "sum(rate(http_requests_total{$PAY}[1m]))") \
    <(range "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{$PAY}[1m]))) * 1000") |
  join -t, - <(range "histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{$PAY}[1m]))) * 1000") |
  join -t, - <(range "(sum(rate(http_requests_total{$PAY,code=~\"5..\"}[1m])) or vector(0)) / sum(rate(http_requests_total{$PAY}[1m]))") |
  join -t, - <(range "count(kube_pod_status_ready{namespace=\"$NS_CDE\",condition=\"true\",pod=~\"payments-api-.*\"} == 1)") |
  join -t, - <(range "count(kube_pod_status_ready{namespace=\"$NS_CDE\",condition=\"true\",pod=~\"ledger-.*\"} == 1)") |
  awk -F, -v t0="$T0" 'BEGIN{OFS=","} {$1 = $1 - t0; print}'
} > "$OUT/loadtest-timeseries.csv"

BEST="$(jq -r '[.[] | select(.within_slo) | .step] | max // "none"' <<<"$ROWS")"
{
  echo "# Load test: payments capacity on kind"
  echo
  echo "Run $(date -u -r "$T0" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date -u -d "@$T0" '+%Y-%m-%d %H:%M UTC'): k6 in the cluster, steps of $STEPS payments/s, each ramped over ${RAMP}s and held for $HOLD, at most $MAX_VUS concurrent requests."
  echo "Background traffic from the traffic generator ($(printf '%.1f' "$BASELINE") payments/s) is part of the offered rate."
  echo "Every figure is server-side (Prometheus), over the last ${WINDOW}s of each hold."
  echo "Cluster: kind, 1 control-plane node and 3 workers (one CDE) sharing a $(docker info --format '{{.NCPU}}' 2>/dev/null || echo '?')-CPU, $(( $(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0) / 1073741824 )) GB Docker VM."
  echo
  echo "| Offered (req/s) | Served (req/s) | p50 | p95 | p99 | 5xx | payments-api pods | ledger pods | CPU payments-api / ledger / PostgreSQL / cluster (cores) | Within SLO |"
  echo "|---:|---:|---:|---:|---:|---:|---:|---:|---|:---:|"
  jq -r '.[] | "| \(.offered | . * 10 | round / 10) | \((.served // 0) | . * 10 | round / 10) | \(.p50_ms | round) ms | \(.p95_ms | round) ms | \(.p99_ms | round) ms | \(((.error_ratio // 0) * 100) | . * 100 | round / 100) % | \(.payments_api_pods // "?") | \(.ledger_pods // "?") | \([.cpu_payments_api, .cpu_ledger, .cpu_postgres, .cpu_cluster] | map((. // 0) * 100 | round / 100 | tostring) | join(" / ")) | \(if .within_slo then "yes" else "**no**" end) |"' <<<"$ROWS"
  echo
  echo "SLO per step: p99 <= 300 ms, 5xx <= 0.1 %, served >= 95 % of offered."
  echo
  if [[ "$BEST" == none ]]; then
    echo "**Highest rate sustained within the SLOs: none of the steps.**"
  else
    echo "**Highest rate sustained within the SLOs: $BEST payments/s offered by k6 (plus background).**"
  fi
  echo
  echo "k6 over the whole run: $(jq -r '"\(.http_reqs.count) requests, \(.dropped_iterations.count // 0) dropped (concurrency limit reached), server errors \((.server_errors.rate * 100) | . * 1000 | round / 1000) %, p99 \(.payment_latency_ms["p(99)"] | round) ms"' "$OUT/loadtest-k6-summary.json")."
  echo
  echo "Files: \`loadtest-steps.json\` (per step), \`loadtest-timeseries.csv\` (every 15 s), \`loadtest-k6-summary.json\` (client side)."
} > "$OUT/loadtest.md"
cat "$OUT/loadtest.md"
echo
ok "load test report written to $OUT/loadtest.md (highest step within SLO: $BEST)"
