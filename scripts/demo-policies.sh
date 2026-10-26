#!/usr/bin/env bash
# Phase 2 acceptance B1: admission control rejects what must never run in
# FinCore namespaces, and admits a signed, compliant workload.
#
# Every request below is a real create against the API server (nothing is
# dry-run); each rejection is asserted on Kyverno's (or Pod Security's) message.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl docker jq

FAILURES=0
RUN="$(date +%s)"
SIGNED="$REGISTRY/fincore/payments-api:$(kind_tag payments-api)"

log "preparing images in the registry (pushed by scripts/publish-image.sh)"
src="fincore/notifier:$(kind_tag notifier)"
UNSIGNED="$("$ROOT/scripts/publish-image.sh" "$src" --as "fincore/demo-unsigned:$RUN" --unsigned)"
NO_SBOM="$("$ROOT/scripts/publish-image.sh" "$src" --as "fincore/demo-no-sbom:$RUN" --no-sbom)"
# A signed tag that is later overwritten with different, unsigned content.
"$ROOT/scripts/publish-image.sh" "$src" --as "fincore/demo-retagged:$RUN" >/dev/null
docker build -q -f "$ROOT/build/Dockerfile" --build-arg SERVICE=netprobe --build-arg PKG=./tools/netprobe \
  -t "fincore/demo-retagged:$RUN" "$ROOT" >/dev/null
"$ROOT/scripts/publish-image.sh" "fincore/demo-retagged:$RUN" --unsigned >/dev/null
RETAGGED="$REGISTRY/fincore/demo-retagged:$RUN"

# pod <name> <image> [jq filter applied to a compliant CDE pod spec] -> JSON
pod() {
  jq -n --arg name "$1" --arg image "$2" '{
    apiVersion: "v1", kind: "Pod",
    metadata: {name: $name, labels: {"app.kubernetes.io/name": "policy-demo"}},
    spec: {
      nodeSelector: {"fincore.io/node-role": "cde"},
      tolerations: [{key: "fincore.io/zone", operator: "Equal", value: "cde", effect: "NoSchedule"}],
      automountServiceAccountToken: false,
      securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{
        name: "app", image: $image,
        resources: {requests: {cpu: "10m", memory: "16Mi"}, limits: {memory: "64Mi"}},
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
      }]
    }}' | jq "${3:-.}"
}

# case <title> <namespace> <expected message fragment | ADMIT> <manifest JSON>
case_() {
  local title="$1" ns="$2" want="$3" manifest="$4" out rc=0
  echo
  log "$title"
  out="$(kubectl -n "$ns" create -f - 2>&1 <<<"$manifest")" || rc=$?
  if [[ "$want" == ADMIT ]]; then
    if [[ $rc == 0 ]]; then
      ok "admitted: $out"
    else
      warn "FAIL: expected admission, got: $out"; FAILURES=$((FAILURES + 1))
    fi
    return
  fi
  echo "   $out" | fold -s -w 160 | sed '2,$s/^/   /'
  if [[ $rc != 0 && "$out" == *"$want"* ]]; then
    ok "rejected as expected"
  else
    warn "FAIL: expected rejection containing '$want'"; FAILURES=$((FAILURES + 1))
    kubectl -n "$ns" delete -f - --ignore-not-found >/dev/null 2>&1 <<<"$manifest" || true
  fi
}

case_ "1. unsigned image" "$NS_CDE" "is not signed by the FinCore release pipeline" \
  "$(pod "demo-unsigned-$RUN" "$UNSIGNED")"

case_ "2. signed image without an SBOM attestation" "$NS_CDE" "no signed SBOM attestation" \
  "$(pod "demo-no-sbom-$RUN" "$NO_SBOM")"

case_ "3. signed tag overwritten with unsigned content (the signature binds the digest, not the tag)" "$NS_CDE" \
  "is not signed by the FinCore release pipeline" "$(pod "demo-retagged-$RUN" "$RETAGGED")"

case_ "4. image from a foreign registry" "$NS_CDE" "images must come from $REGISTRY/fincore/" \
  "$(pod "demo-foreign-$RUN" "docker.io/library/nginx:1.29")"

case_ "5. root container in a Deployment (rejected at the Deployment, before any pod exists)" "$NS_APP" \
  "root containers are not allowed" "$(jq -n --argjson spec "$(pod x "$SIGNED" '.spec | del(.nodeSelector, .tolerations) | .securityContext.runAsUser = 0')" '{
    apiVersion: "apps/v1", kind: "Deployment", metadata: {name: "demo-root"},
    spec: {replicas: 1, selector: {matchLabels: {app: "demo-root"}},
           template: {metadata: {labels: {app: "demo-root"}}, spec: $spec}}}')"

case_ "6. root container as a bare Pod (Pod Security 'restricted' and Kyverno both forbid it)" "$NS_CDE" \
  "runAsUser=0" "$(pod "demo-root-pod-$RUN" "$SIGNED" '.spec.securityContext.runAsUser = 0 | .spec.securityContext.runAsNonRoot = false')"

case_ "7. writable root filesystem" "$NS_CDE" "readOnlyRootFilesystem must be true" \
  "$(pod "demo-writable-$RUN" "$SIGNED" '.spec.containers[0].securityContext.readOnlyRootFilesystem = false')"

case_ "8. no memory limit" "$NS_CDE" "limits.memory are required" \
  "$(pod "demo-nolimits-$RUN" "$SIGNED" 'del(.spec.containers[0].resources.limits)')"

case_ "9. a pod outside the zone tolerating the CDE taint" "$NS_APP" "may tolerate the" \
  "$(pod "demo-sneak-$RUN" "$SIGNED" 'del(.spec.nodeSelector)')"

case_ "10. a cardholder-data-zone pod off the CDE nodes" "$NS_CDE" "must run on CDE nodes" \
  "$(pod "demo-offzone-$RUN" "$SIGNED" 'del(.spec.nodeSelector, .spec.tolerations)')"

case_ "11. control: signed, SBOM-attested, compliant image" "$NS_CDE" ADMIT \
  "$(pod "demo-compliant-$RUN" "$SIGNED")"
img="$(kubectl -n "$NS_CDE" get pod "demo-compliant-$RUN" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || true)"
echo "   image as admitted: $img"
if [[ "$img" == "$SIGNED@sha256:"* ]]; then
  ok "tag resolved to the verified digest at admission"
else
  warn "FAIL: image was not pinned to its digest"; FAILURES=$((FAILURES + 1))
fi
kubectl -n "$NS_CDE" delete pod "demo-compliant-$RUN" --wait=false >/dev/null 2>&1 || true

echo
log "policies in force"
kubectl get validatingpolicies.policies.kyverno.io,imagevalidatingpolicies.policies.kyverno.io
echo
[[ $FAILURES == 0 ]] || die "$FAILURES assertion(s) failed"
ok "DEMO PASSED: unsigned, unattested, foreign, root and non-compliant workloads are rejected; signed ones are admitted by digest"
