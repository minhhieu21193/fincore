#!/usr/bin/env bash
# Phase 2 acceptance B3: NetworkPolicies isolate the cardholder-data zone.
#
# A probe (tools/netprobe: signed, non-root, so it passes the same admission
# policies as the services) attempts TCP connections and every result is asserted:
#   - from outside the zone (namespace fincore): the ledger, payments-api,
#     PostgreSQL and the queue are unreachable; the internet is reachable
#     (control: the probe and the network work, only the policy blocks);
#   - from inside the zone (a pod with no allow rule): no internet, and no
#     access to the ledger (only payments-api may call it);
#   - the legitimate path still works: a payment is captured end to end.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl docker jq curl

FAILURES=0
CONTROL_TARGET="1.1.1.1:443"
TIMEOUT=4s

log "building and publishing the probe image (signed + SBOM, like every FinCore image)"
tag="netprobe-$(git -C "$ROOT" rev-parse --short HEAD)"
docker build -q -f "$ROOT/build/Dockerfile" --build-arg SERVICE=netprobe --build-arg PKG=./tools/netprobe \
  -t "fincore/netprobe:$tag" "$ROOT" >/dev/null
PROBE="$("$ROOT/scripts/publish-image.sh" "fincore/netprobe:$tag")"

# probe <namespace> <name> <cde:true|false> <delay> <targets...>: prints netprobe's report.
probe() {
  local ns="$1" name="$2" cde="$3" delay="$4"; shift 4
  local placement=""
  if [[ "$cde" == true ]]; then
    placement='"nodeSelector": {"fincore.io/node-role": "cde"},
      "tolerations": [{"key": "fincore.io/zone", "operator": "Equal", "value": "cde", "effect": "NoSchedule"}],'
  fi
  kubectl -n "$ns" delete pod "$name" --ignore-not-found --wait=true >/dev/null
  kubectl -n "$ns" apply -f - >/dev/null <<JSON
{
  "apiVersion": "v1", "kind": "Pod",
  "metadata": {"name": "$name", "labels": {"app.kubernetes.io/name": "netprobe"}},
  "spec": {
    $placement
    "restartPolicy": "Never",
    "automountServiceAccountToken": false,
    "securityContext": {"runAsNonRoot": true, "runAsUser": 65532, "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{
      "name": "netprobe", "image": "$PROBE",
      "args": ["-timeout", "$TIMEOUT", "-delay", "$delay"$(printf ', "%s"' "$@")],
      "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"memory": "32Mi"}},
      "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}}
    }]
  }
}
JSON
  wait_for "probe $ns/$name to finish" 120 bash -c \
    "[[ \$(kubectl -n $ns get pod $name -o jsonpath='{.status.phase}') == Succeeded ]]"
  kubectl -n "$ns" logs "$name"
  kubectl -n "$ns" delete pod "$name" --wait=false >/dev/null
}

# expect <report> <target name> <OPEN|BLOCKED>
expect() {
  local line got
  line="$(grep "^$2 " <<<"$1" || true)"
  got="$(awk '{print $3}' <<<"$line")"
  if [[ "$got" == "$3" ]]; then
    ok "$2: $3"
  else
    warn "FAIL: $2 expected $3, got: ${line:-no result}"
    FAILURES=$((FAILURES + 1))
  fi
}

CDE_SVC="$NS_CDE.svc.cluster.local"
log "1. from OUTSIDE the zone: a pod in namespace $NS_APP (where the notifier runs)"
out="$(probe "$NS_APP" netprobe-outside false 0s \
  "ledger=ledger.$CDE_SVC:8080" \
  "payments-api=payments-api.$CDE_SVC:8080" \
  "postgres=postgres.fincore-data.svc.cluster.local:5432" \
  "queue=elasticmq.fincore-data.svc.cluster.local:9324" \
  "internet(control)=$CONTROL_TARGET")"
indent <<<"$out"
expect "$out" ledger BLOCKED
expect "$out" payments-api BLOCKED
expect "$out" postgres BLOCKED
expect "$out" queue BLOCKED
expect "$out" "internet(control)" OPEN

log "2. from INSIDE the zone: a pod in $NS_CDE on a CDE node, with no allow rule of its own"
# kindnet adds a new pod to its enforced set about a second after the pod starts
# (docs/phase-2-results.md, "Findings"); the probe measures the steady state.
# The VPC CNI on EKS behaves the same in its default "standard" mode.
in="$(probe "$NS_CDE" netprobe-inside true 10s \
  "internet=$CONTROL_TARGET" \
  "ledger=ledger.$CDE_SVC:8080" \
  "postgres=postgres.fincore-data.svc.cluster.local:5432")"
indent <<<"$in"
expect "$in" internet BLOCKED
expect "$in" ledger BLOCKED
expect "$in" postgres BLOCKED

log "3. the legitimate path still works: traffic generator -> payments-api -> ledger -> PostgreSQL / queue"
kubectl -n "$NS_CDE" port-forward svc/payments-api 18090:8080 >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT
wait_for "port-forward" 30 curl -sf http://localhost:18090/readyz
resp="$(curl -s -X POST http://localhost:18090/v1/payments -H 'Content-Type: application/json' \
  -H "Idempotency-Key: netpol-$(date +%s)" \
  -d '{"merchant_id":"m_netpol","amount":1000,"currency":"USD","card_token":"tok_visa"}')"
echo "   $resp"
if [[ "$(jq -r .status <<<"$resp")" == captured ]]; then
  ok "payment captured: payments-api -> ledger and both data stores are reachable where allowed"
else
  warn "FAIL: payment was not captured"
  FAILURES=$((FAILURES + 1))
fi
gen="$(kubectl -n "$NS_APP" logs deploy/traffic-generator --since=60s 2>/dev/null | grep -ciE 'error|fail' || true)"
echo "   traffic generator errors in the last 60s: $gen"

log "policies in force"
kubectl -n "$NS_CDE" get networkpolicy
echo
[[ $FAILURES == 0 ]] || die "$FAILURES assertion(s) failed"
ok "DEMO PASSED: the cardholder-data zone is isolated by default-deny NetworkPolicies"
