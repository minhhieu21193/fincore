# Canary rollback

Every release of payments-api and the ledger is an Argo Rollouts canary (10 → 30 → 60 → 100 %), analysed against Prometheus every 30 s (after a 60 s delay): success rate ≥ 99 % and p95 ≤ 300 ms for the canary pods, 1 failed measurement tolerated. A failing analysis aborts the rollout by itself and all traffic goes back to the stable version.

## A rollout was aborted

```
kubectl argo rollouts get rollout payments-api -n fincore-cde        # which revision, which step
kubectl -n fincore-cde get analysisrun --sort-by=.metadata.creationTimestamp | tail -3
kubectl -n fincore-cde get analysisrun <name> -o json | jq '.status.metricResults[] | {name, measurements: [.measurements[].value]}'
```

1. **Was the stable version healthy during the analysis?** Grafana → FinCore / Service RED, "Requests by version" and latency, over the canary's minutes.
   - Stable healthy, canary not: the build is bad. Leave it aborted, revert or fix in git. The abort already protects users.
   - Stable just as bad: the environment was degraded, not the build. Fix the environment, then `kubectl argo rollouts retry rollout <name> -n fincore-cde`.
2. Retry at most 3 times; between retries, look for what changed.

## On kind: one canary at a time

The kind cluster shares 6 CPUs. A change that touches both services' pod templates (a shared chart value) starts two canaries at once, and they distort each other's analysis. Release them one after the other (`scripts/deploy-kind.sh` waits for the previous rollout to settle).

## Abort by hand

`kubectl argo rollouts abort <rollout> -n fincore-cde`: traffic goes to stable at once. Then revert the image tag in git, or Argo CD will start the canary again.

## Emergency promotion (the stable version *is* the incident)

The analysis cannot tell a fix from a regression when the stable version is causing the outage: both look broken (postmortem 2026-10-28). Then, and only then:

1. Name an owner in the incident channel; state why the stable version is the cause (evidence: a graph, a trace, a query).
2. `kubectl argo rollouts retry rollout <name> -n fincore-cde && kubectl argo rollouts promote <name> -n fincore-cde --full`
3. Watch the RED dashboard for 10 minutes; be ready to `abort`.
4. Record it in the change log (`docs/decisions-log.md` on this project) and in the postmortem.

Thresholds are never changed to let a release through.
