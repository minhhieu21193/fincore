# Decisions log

Local, reversible decisions taken during unattended runs, one line each:
date: question → choice (why).

- 2026-10-26: Docker Desktop was reset to 2 CPU / 3 GB through its GUI → restored to 4 CPU / 8 GB (owner chose it; the previous working setting).
- 2026-10-26: The Phase 2 kind stack swapped at 8 GB → 10 GB, plus a slimmer kind footprint: 1 control plane + 2 workers + 1 CDE worker, Vault anti-affinity relaxed on kind only, lighter Argo CD (owner chose it; AWS values unchanged).
- 2026-10-27: The kind platform used ~3.6–3.8 of 4 CPUs at idle, which caused false canary aborts → 6 CPUs / 10 GB, and on kind releases never overlap (deploy-kind.sh waits for every Rollout to settle) (owner chose it; thresholds unchanged).
- 2026-10-27: Fresh `make kind-up` for the Phase 2 acceptance run, at 6 CPUs / 10 GB (pre-approved: recreating the kind cluster).

## Waiting for owner

(nothing)
