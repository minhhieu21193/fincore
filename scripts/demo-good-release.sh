#!/usr/bin/env bash
# Counterpart of demo-bad-release.sh: a healthy build goes through every
# canary step (10 -> 30 -> 60 -> 100%) with passing analysis and is promoted
# automatically. Proves the analysis has no false positives.
#
# The release commit is reverted at the end (rollbackWindow makes that an
# immediate switch back to the previous ReplicaSet) unless --keep is given.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl jq git yq
KEEP=0; [[ "${1:-}" == "--keep" ]] && KEEP=1

ro() { kubectl -n fincore get rollout payments-api -o json; }
[[ "$(ro | jq -r .status.phase)" == Healthy ]] || die "payments-api rollout must be Healthy before the demo"

STABLE_TAG="$(kind_tag payments-api)"
STABLE_HASH="$(ro | jq -r .status.stableRS)"
NEW_TAG="${STABLE_TAG%%-*}-rc.$(date +%s)"
log "stable: payments-api:$STABLE_TAG ($STABLE_HASH) -> releasing healthy build payments-api:$NEW_TAG"
T0=$SECONDS
"$ROOT/scripts/deploy-kind.sh" payments-api "$NEW_TAG"
RELEASE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"

wait_for "canary ReplicaSet" 180 bash -c "[[ \$(kubectl -n fincore get rollout payments-api -o jsonpath='{.status.currentPodHash}') != '$STABLE_HASH' ]]"
CANARY_HASH="$(ro | jq -r .status.currentPodHash)"
ok "canary started after $(( SECONDS - T0 ))s (hash $CANARY_HASH)"

last=""
while :; do
  s="$(ro)"
  line="phase=$(jq -r .status.phase <<<"$s") step=$(jq -r '.status.currentStepIndex // "-"' <<<"$s")/$(jq '.spec.strategy.canary.steps | length' <<<"$s") weight=$(jq -r '.status.canary.weights.canary.weight // "-"' <<<"$s") analysis=$(jq -r '.status.canary.currentBackgroundAnalysisRunStatus.status // "-"' <<<"$s")"
  [[ "$line" != "$last" ]] && printf '   [%3ss] %s\n' "$(( SECONDS - T0 ))" "$line" && last="$line"
  [[ "$(jq -r '.status.abort // false' <<<"$s")" == true ]] && die "healthy build was ABORTED: $(jq -r .status.message <<<"$s")"
  if [[ "$(jq -r .status.stableRS <<<"$s")" == "$CANARY_HASH" && "$(jq -r .status.phase <<<"$s")" == Healthy ]]; then
    T_DONE=$(( SECONDS - T0 )); break
  fi
  (( SECONDS - T0 > 1200 )) && die "not promoted after 20 minutes"
  sleep 5
done
ok "promoted to 100% after ${T_DONE}s"

AR="$(kubectl -n fincore get analysisrun -l rollouts-pod-template-hash="$CANARY_HASH" -o json | jq -r '.items | sort_by(.metadata.creationTimestamp) | last')"
echo "   AnalysisRun $(jq -r .metadata.name <<<"$AR"): $(jq -r .status.phase <<<"$AR")"
jq -r '.status.metricResults[] | "     \(.name): \(.phase) — \([.measurements[] | "\(.phase):\(.value)"] | join(", "))"' <<<"$AR"
PASSED="$(jq '[.status.metricResults[] | .measurements[] | select(.phase == "Successful")] | length' <<<"$AR")"
[[ "$PASSED" -ge 2 ]] || die "promotion was not backed by successful measurements"
ok "promotion backed by $PASSED successful measurement(s)"

if [[ $KEEP == 0 ]]; then
  log "reverting the release commit (rollbackWindow: immediate switch back)"
  git -C "$ROOT" revert --no-edit "$RELEASE_COMMIT" >/dev/null
  kubectl -n argocd annotate application payments-api argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  wait_for "rollout back on $STABLE_HASH" 300 bash -c "s=\$(kubectl -n fincore get rollout payments-api -o json); [[ \$(jq -r .status.phase <<<\"\$s\") == Healthy && \$(jq -r .status.stableRS <<<\"\$s\") == '$STABLE_HASH' ]]"
  ok "back on payments-api:$STABLE_TAG"
fi
echo
ok "DEMO PASSED: healthy build promoted through all canary steps in ${T_DONE}s"
