#!/usr/bin/env bash
# Phase 3 acceptance C1: one payment followed through every signal.
#
#   1. A payment is sent with a sampled W3C traceparent, so it is traced
#      whatever the sampling ratio.
#   2. Tempo has its trace, with spans from payments-api AND the ledger.
#   3. Loki has its log lines (both services), found by the same trace_id, and
#      Grafana's Loki data source turns that trace_id into a link to Tempo.
#   4. The ledger holds the balanced double entry of the same payment.
#   5. Grafana serves the FinCore dashboards, and the business panels have data
#      (payments flowing, ledger imbalance exactly 0).
#
# Loki and Tempo are queried through the API server's service proxy;
# payments-api, the ledger and Grafana through port-forwards, which the kubelet
# opens without crossing the CDE NetworkPolicies.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl curl jq openssl

MON=monitoring
proxy() { # service:port path -> body
  kubectl get --raw "/api/v1/namespaces/$MON/services/http:$1/proxy$2"
}
urlencode() { jq -rn --arg v "$1" '$v | @uri'; }

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
forward() { # namespace svc local-port remote-port
  kubectl -n "$1" port-forward "svc/$2" "$3:$4" >/dev/null 2>&1 &
  PIDS+=($!)
}
forward "$(ns_of payments-api)" payments-api 18180 8080
forward "$(ns_of ledger)" ledger 18181 8080
forward "$MON" kube-prometheus-stack-grafana 18182 80
API=http://localhost:18180 LEDGER=http://localhost:18181 GRAFANA=http://localhost:18182
wait_for "port-forwards" 30 curl -sf "$API/readyz"
wait_for "port-forwards" 30 curl -sf "$LEDGER/readyz"
wait_for "port-forwards" 30 curl -sf "$GRAFANA/api/health"
# Data sources are only listed to admins; the password is the chart's generated one.
GRAFANA_AUTH="$(kubectl -n "$MON" get secret kube-prometheus-stack-grafana -o json |
  jq -r '"\(.data["admin-user"] | @base64d):\(.data["admin-password"] | @base64d)"')"
grafana() { # path -> body; retried, because a Grafana restart breaks the port-forward
  local i
  for i in 1 2 3 4 5; do
    curl -sf --max-time 10 -u "$GRAFANA_AUTH" "$GRAFANA$1" && return 0
    warn "Grafana request $1 failed (attempt $i), reconnecting"
    kill "${PIDS[2]}" 2>/dev/null || true
    forward "$MON" kube-prometheus-stack-grafana 18182 80; PIDS[2]="${PIDS[${#PIDS[@]}-1]}"
    sleep 5
  done
  die "Grafana did not answer $1"
}

FAILURES=0
check() { # description, then a command that succeeds when the check passes
  local d="$1"; shift
  if "$@"; then ok "$d"; else warn "FAIL: $d"; FAILURES=$((FAILURES + 1)); fi
}

log "0. observability stack"
for w in statefulset/loki statefulset/tempo daemonset/fluent-bit deployment/kube-prometheus-stack-grafana; do
  kubectl -n "$MON" rollout status "$w" --timeout=300s >/dev/null
done
ok "Loki, Tempo, Fluent Bit (one per node: $(kubectl -n "$MON" get ds fluent-bit -o jsonpath='{.status.numberReady}')) and Grafana are ready"

TRACE_ID="$(openssl rand -hex 16)"
SPAN_ID="$(openssl rand -hex 8)"
RUN="$(date +%s)"
echo
log "1. payment with traceparent 00-$TRACE_ID-$SPAN_ID-01"
RESP="$(curl -s -X POST "$API/v1/payments" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: obs-$RUN" -H "traceparent: 00-$TRACE_ID-$SPAN_ID-01" \
  -d "{\"merchant_id\":\"m_obs_$RUN\",\"amount\":4200,\"currency\":\"USD\",\"card_token\":\"tok_visa\"}")"
echo "   $RESP"
PAYMENT_ID="$(jq -r .id <<<"$RESP")"
check "payment captured (id $PAYMENT_ID)" test "$(jq -r .status <<<"$RESP")" == captured

echo
log "2. Tempo: the trace"
trace_services() {
  proxy tempo:3200 "/api/v2/traces/$TRACE_ID" 2>/dev/null |
    jq -r '[.trace.resourceSpans[]?.resource.attributes[]? | select(.key == "service.name") | .value.stringValue] | unique | join(" ")'
}
SERVICES=""
start=$SECONDS
until [[ "$SERVICES" == *ledger* && "$SERVICES" == *payments-api* ]] || (( SECONDS - start > 90 )); do
  sleep 3; SERVICES="$(trace_services || true)"
done
TRACE="$(proxy tempo:3200 "/api/v2/traces/$TRACE_ID" 2>/dev/null || echo '{}')"
jq -r '.trace.resourceSpans[]? as $rs
  | ($rs.resource.attributes[] | select(.key == "service.name") | .value.stringValue) as $svc
  | $rs.scopeSpans[].spans[]
  | "   \($svc): \(.name)  \(((.endTimeUnixNano | tonumber) - (.startTimeUnixNano | tonumber)) / 1e6 | floor) ms"' <<<"$TRACE" | sort -u
check "trace $TRACE_ID has spans from payments-api and the ledger (found: ${SERVICES:-none})" \
  bash -c "[[ '$SERVICES' == *ledger* && '$SERVICES' == *payments-api* ]]"

echo
log "3. Loki: the log lines of the same trace"
QUERY="{namespace=~\"fincore|fincore-cde\"} |= \"$TRACE_ID\""
loki_lines() {
  proxy loki:3100 "/loki/api/v1/query_range?query=$(urlencode "$QUERY")&since=15m&limit=50" 2>/dev/null |
    jq -r '.data.result[]? | .stream.app as $app | .values[] | "\($app) \(.[1])"'
}
LINES=""
start=$SECONDS
until [[ "$LINES" == *"ledger "* && "$LINES" == *"payments-api "* ]] || (( SECONDS - start > 90 )); do
  sleep 3; LINES="$(loki_lines || true)"
done
echo "   query: $QUERY"
while IFS= read -r l; do [[ -z "$l" ]] || echo "   ${l:0:220}"; done <<<"$LINES"
check "log lines from payments-api and the ledger carry trace_id $TRACE_ID" \
  bash -c "[[ \"\$1\" == *'ledger '* && \"\$1\" == *'payments-api '* ]]" _ "$LINES"
# The same regex Grafana's Loki data source uses to link a line to its trace.
REGEX="$(grafana /api/datasources/uid/loki | jq -r '.jsonData.derivedFields[0].matcherRegex')"
LINKED="$(grep -oE "$REGEX" <<<"$LINES" | head -1 || true)"
check "Grafana's derived field ($REGEX) links the line to the trace" bash -c "[[ '$LINKED' == *$TRACE_ID* ]]"

echo
log "4. ledger: the same payment's double entry"
TX="$(curl -sf "$LEDGER/v1/transactions/payment:$PAYMENT_ID:capture")"
jq -r '.entries[] | "   \(.direction)\t\(.account)\t\(.amount)"' <<<"$TX"
check "debits = credits = 4200" test "$(jq '[.entries[] | select(.direction == "debit") | .amount] | add' <<<"$TX"):$(jq '[.entries[] | select(.direction == "credit") | .amount] | add' <<<"$TX")" == 4200:4200

echo
log "5. Grafana: dashboards and data sources"
DASH="$(grafana '/api/search?tag=fincore' | jq -r '[.[].title] | sort | join(", ")')"
echo "   dashboards: $DASH"
check "business, RED, platform and SLO dashboards are provisioned" \
  test "$DASH" == "FinCore / Business, FinCore / Platform, FinCore / SLOs, FinCore / Service RED"
DS="$(grafana /api/datasources | jq -r '[.[].type] | sort | unique | join(",")')"
check "data sources: Prometheus, Alertmanager, Loki, Tempo ($DS)" test "$DS" == "alertmanager,loki,prometheus,tempo"
prom() { # instant query through Grafana's Prometheus data source -> first value
  grafana "/api/datasources/proxy/uid/prometheus/api/v1/query?query=$(urlencode "$1")" |
    jq -r '.data.result[0].value[1] // "none"'
}
RATE="$(prom 'sum(rate(payments_total[2m]))')"
IMB="$(prom 'max(abs(ledger_imbalance_minor_units))')"
CAPTURE="$(prom 'sum(rate(payments_total{status="captured"}[5m])) / sum(rate(payments_total[5m]))')"
printf '   payments/s %.2f   capture rate %.1f%%   ledger imbalance %s\n' "$RATE" "$(jq -n "$CAPTURE * 100")" "$IMB"
check "business dashboard: payments are flowing" test "$(jq -n "$RATE > 0" 2>/dev/null)" == true
check "business dashboard: ledger imbalance is exactly 0" test "$IMB" == 0

echo
[[ $FAILURES == 0 ]] || die "$FAILURES check(s) failed"
ok "DEMO PASSED: payment $PAYMENT_ID followed from its trace ($TRACE_ID) to its log lines to its ledger entry"
