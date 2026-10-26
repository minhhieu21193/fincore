#!/usr/bin/env bash
# Phase 1 acceptance A1 on kind: a payment flows end to end
#   payments-api -> ledger -> outbox -> SQS-compatible queue (ElasticMQ) -> notifier -> merchant webhook
# and the guarantees around it hold (idempotency, double entry, declines).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl curl jq

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

forward() { # svc local-port
  kubectl -n "$(ns_of "$1")" port-forward "svc/$1" "$2:8080" >/dev/null 2>&1 &
  PIDS+=($!)
}
forward payments-api 18080
forward ledger 18081
forward webhook-sink 18083
API=http://localhost:18080 LEDGER=http://localhost:18081 SINK=http://localhost:18083
wait_for "port-forwards" 30 curl -sf "$API/readyz"
wait_for "port-forwards" 30 curl -sf "$LEDGER/readyz"
wait_for "port-forwards" 30 curl -sf "$SINK/readyz"

FAILURES=0
pass() { ok "$1"; }
fail() { warn "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
post() { # key body -> writes headers+body to $TMP
  curl -s -D "$TMP.h" -o "$TMP.b" -X POST "$API/v1/payments" \
    -H 'Content-Type: application/json' -H "Idempotency-Key: $1" -d "$2"
  STATUS=$(awk 'NR==1{print $2}' "$TMP.h")
  REPLAYED=$( { grep -i '^idempotent-replayed:' "$TMP.h" || true; } | awk '{print $2}' | tr -d '\r')
}
TMP="$(mktemp -d)/resp"
RUN="$(date +%s)"
MERCHANT="m_e2e_$RUN"
AMOUNT=1999
FEE=$(( AMOUNT * 290 / 10000 ))
BODY="{\"merchant_id\":\"$MERCHANT\",\"amount\":$AMOUNT,\"currency\":\"USD\",\"card_token\":\"tok_visa\"}"

log "1. create payment (Idempotency-Key e2e-$RUN)"
post "e2e-$RUN" "$BODY"
PAYMENT_ID=$(jq -r .id "$TMP.b")
FIRST_BODY=$(cat "$TMP.b")
echo "   $FIRST_BODY"
d="HTTP 201 and status=captured"
if [[ $STATUS == 201 && $(jq -r .status "$TMP.b") == captured ]]; then pass "$d"; else fail "$d"; fi
d="first response is not a replay"
if [[ $REPLAYED == false ]]; then pass "$d"; else fail "$d"; fi

log "2. retry with the same key and body"
post "e2e-$RUN" "$BODY"
d="replayed byte-for-byte (Idempotent-Replayed: true)"
if [[ $STATUS == 201 && $REPLAYED == true && "$(cat "$TMP.b")" == "$FIRST_BODY" ]]; then pass "$d"; else fail "$d"; fi

log "3. reuse the key with a different body"
post "e2e-$RUN" "${BODY/$AMOUNT/5000}"
d="rejected with 422 idempotency_key_reused"
if [[ $STATUS == 422 && $(jq -r .error "$TMP.b") == idempotency_key_reused ]]; then pass "$d"; else fail "$d"; fi

log "4. ledger: balanced double entry for the capture"
TX=$(curl -sf "$LEDGER/v1/transactions/payment:$PAYMENT_ID:capture")
echo "   $(jq -c '[.entries[] | {account, direction, amount}]' <<<"$TX")"
DEBITS=$(jq '[.entries[] | select(.direction=="debit") | .amount] | add' <<<"$TX")
CREDITS=$(jq '[.entries[] | select(.direction=="credit") | .amount] | add' <<<"$TX")
d="debits ($DEBITS) == credits ($CREDITS) == amount ($AMOUNT)"
if [[ $DEBITS == "$CREDITS" && $DEBITS == "$AMOUNT" ]]; then pass "$d"; else fail "$d"; fi
BAL=$(curl -sf "$LEDGER/v1/accounts/liabilities:merchant:$MERCHANT/balance" | jq .balance)
d="merchant balance derived from entries = $((AMOUNT - FEE)) (amount - 2.90% fee)"
if [[ $BAL == $((AMOUNT - FEE)) ]]; then pass "$d"; else fail "$d"; fi
INV=$(curl -sf "$LEDGER/v1/invariants")
echo "   $INV"
d="whole ledger balanced (sum debits = sum credits)"
if [[ $(jq .balanced <<<"$INV") == true ]]; then pass "$d"; else fail "$d"; fi

log "5. outbox -> queue -> notifier -> signed webhook"
got_webhook() { [[ $(curl -sf "$SINK/received?payment_id=$1" | jq '.count') -ge 1 ]]; }
start=$SECONDS
until got_webhook "$PAYMENT_ID" || (( SECONDS - start > 60 )); do sleep 1; done
EVENTS=$(curl -sf "$SINK/received?payment_id=$PAYMENT_ID")
echo "   $(jq -c '[.events[] | {event_type, event_id, received_at}]' <<<"$EVENTS")"
d="merchant received exactly one payment.captured webhook ($(( SECONDS - start ))s after capture)"
if [[ $(jq '.count' <<<"$EVENTS") == 1 && $(jq -r '.events[0].event_type' <<<"$EVENTS") == payment.captured ]]; then pass "$d"; else fail "$d"; fi

log "6. declined card"
post "e2e-decline-$RUN" "{\"merchant_id\":\"$MERCHANT\",\"amount\":500,\"currency\":\"USD\",\"card_token\":\"tok_decline\"}"
DECLINED_ID=$(jq -r .id "$TMP.b")
d="HTTP 402, status=failed, reason=card_declined"
if [[ $STATUS == 402 && $(jq -r .failure_reason "$TMP.b") == card_declined ]]; then pass "$d"; else fail "$d"; fi
start=$SECONDS
until got_webhook "$DECLINED_ID" || (( SECONDS - start > 60 )); do sleep 1; done
d="merchant received payment.failed webhook"
if [[ $(curl -sf "$SINK/received?payment_id=$DECLINED_ID" | jq -r '.events[0].event_type') == payment.failed ]]; then pass "$d"; else fail "$d"; fi
d="no ledger entries for the declined payment"
if [[ $(curl -s -o /dev/null -w '%{http_code}' "$LEDGER/v1/transactions/payment:$DECLINED_ID:capture") == 404 ]]; then pass "$d"; else fail "$d"; fi

echo
if [[ $FAILURES == 0 ]]; then
  ok "E2E PASSED: payment $PAYMENT_ID flowed API -> ledger -> outbox -> queue -> webhook"
else
  die "E2E FAILED: $FAILURES check(s) failed"
fi
