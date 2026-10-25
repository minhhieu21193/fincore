#!/usr/bin/env bash
# Phase 1 acceptance A2: a deliberately bad build of payments-api is released
# through GitOps and Argo Rollouts rolls it back automatically.
#
# 1. build payments-api with 50% injected HTTP 500s, bump the tag in git (commit)
# 2. Argo CD syncs; the Rollout starts the canary at 10%
# 3. background analysis compares canary-only success rate / p95 (Prometheus)
#    against the thresholds and fails -> Rollouts aborts, canary scaled to 0,
#    stable keeps serving. No human involved.
# 4. the bad commit is reverted (git stays the source of truth) and the
#    Rollout returns to Healthy on the stable version.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl jq git yq

ro() { kubectl -n fincore get rollout payments-api -o json; }
[[ "$(ro | jq -r .status.phase)" == Healthy ]] || die "payments-api rollout must be Healthy before the demo"
kubectl -n fincore get deploy traffic-generator >/dev/null || die "traffic-generator must be running (it feeds the analysis)"

STABLE_TAG="$(kind_tag payments-api)"
STABLE_HASH="$(ro | jq -r .status.stableRS)"
BAD_TAG="${STABLE_TAG%%-*}-bad.$(date +%s)"
log "stable: payments-api:$STABLE_TAG (ReplicaSet hash $STABLE_HASH)"

log "releasing deliberately bad build payments-api:$BAD_TAG"
T0=$SECONDS
"$ROOT/scripts/deploy-kind.sh" payments-api "$BAD_TAG" --fault-rate 0.5
BAD_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"

log "waiting for Argo CD to sync and the canary to start"
wait_for "canary ReplicaSet" 180 bash -c "[[ \$(kubectl -n fincore get rollout payments-api -o jsonpath='{.status.currentPodHash}') != '$STABLE_HASH' ]]"
CANARY_HASH="$(ro | jq -r .status.currentPodHash)"
ok "canary started after $(( SECONDS - T0 ))s (hash $CANARY_HASH)"

log "watching the rollout (analysis: success rate >= 99%, p95 <= 300ms on canary pods only)"
last=""
while :; do
  s="$(ro)"
  line="phase=$(jq -r .status.phase <<<"$s") step=$(jq -r '.status.currentStepIndex // "-"' <<<"$s") analysis=$(jq -r '.status.canary.currentBackgroundAnalysisRunStatus.status // "-"' <<<"$s") aborted=$(jq -r '.status.abort // false' <<<"$s")"
  [[ "$line" != "$last" ]] && printf '   [%3ss] %s\n' "$(( SECONDS - T0 ))" "$line" && last="$line"
  if [[ "$(jq -r '.status.abort // false' <<<"$s")" == true ]]; then
    T_ABORT=$(( SECONDS - T0 ))
    break
  fi
  if [[ "$(jq -r .status.stableRS <<<"$s")" == "$CANARY_HASH" ]]; then
    die "the bad build was PROMOTED — analysis did not catch it"
  fi
  (( SECONDS - T0 > 900 )) && die "no decision after 15 minutes"
  sleep 5
done
ok "Rollouts ABORTED the canary automatically ${T_ABORT}s after the release commit"
echo "   message: $(ro | jq -r .status.message)"

AR="$(kubectl -n fincore get analysisrun -l rollouts-pod-template-hash="$CANARY_HASH" -o json | jq -r '.items | sort_by(.metadata.creationTimestamp) | last')"
echo "   AnalysisRun $(jq -r .metadata.name <<<"$AR"): $(jq -r .status.phase <<<"$AR")"
jq -r '.status.metricResults[] | "     \(.name): \(.phase) — measurements: \([.measurements[] | "\(.phase):\(.value)"] | join(", "))"' <<<"$AR"

# The abort must come from real evidence, not from missing data.
EVIDENCE="$(jq '[.status.metricResults[] | .measurements[] | select(.phase == "Failed" and .value != "[]" and .value != null)] | length' <<<"$AR")"
[[ "$EVIDENCE" -ge 1 ]] || die "analysis failed without data; this is not a valid detection"
ok "abort backed by $EVIDENCE failed measurement(s) with data"

wait_for "canary scaled to zero" 120 bash -c "[[ \$(kubectl -n fincore get rs -l rollouts-pod-template-hash=$CANARY_HASH -o jsonpath='{.items[0].status.replicas}') == 0 ]]"
STABLE_NOW="$(ro | jq -r .status.stableRS)"
[[ "$STABLE_NOW" == "$STABLE_HASH" ]] || die "stable ReplicaSet changed ($STABLE_NOW)"
ok "canary scaled to 0; 100% of traffic on stable $STABLE_HASH (payments-api:$STABLE_TAG)"

log "restoring git as the source of truth: reverting the bad release commit"
git -C "$ROOT" revert --no-edit "$BAD_COMMIT" >/dev/null
kubectl -n argocd annotate application payments-api argocd.argoproj.io/refresh=normal --overwrite >/dev/null
wait_for "rollout Healthy on the stable version" 300 bash -c "s=\$(kubectl -n fincore get rollout payments-api -o json); [[ \$(jq -r .status.phase <<<\"\$s\") == Healthy && \$(jq -r .status.currentPodHash <<<\"\$s\") == '$STABLE_HASH' ]]"
ok "reverted ($(git -C "$ROOT" rev-parse --short HEAD)); rollout Healthy on payments-api:$STABLE_TAG"

echo
ok "DEMO PASSED: bad build detected by canary analysis and rolled back automatically in ${T_ABORT}s"
if command -v kubectl-argo-rollouts >/dev/null; then
  kubectl argo rollouts get rollout payments-api -n fincore --no-color | head -30
fi
