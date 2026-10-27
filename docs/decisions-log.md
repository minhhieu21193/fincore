# Decisions log

Local, reversible decisions taken during unattended runs, one line each:
date: question → choice (why).

- 2026-10-26: Docker Desktop was reset to 2 CPU / 3 GB through its GUI → restored to 4 CPU / 8 GB (owner chose it; the previous working setting).
- 2026-10-26: The Phase 2 kind stack swapped at 8 GB → 10 GB, plus a slimmer kind footprint: 1 control plane + 2 workers + 1 CDE worker, Vault anti-affinity relaxed on kind only, lighter Argo CD (owner chose it; AWS values unchanged).
- 2026-10-27: The kind platform used ~3.6–3.8 of 4 CPUs at idle, which caused false canary aborts → 6 CPUs / 10 GB, and on kind releases never overlap (deploy-kind.sh waits for every Rollout to settle) (owner chose it; thresholds unchanged).
- 2026-10-27: Fresh `make kind-up` for the Phase 2 acceptance run, at 6 CPUs / 10 GB (pre-approved: recreating the kind cluster).
- 2026-10-27: A healthy canary was aborted on p95 at 6 CPUs; whole-VM CPU bursts (1–4 s) came mostly from the kube-apiserver (GC on a ~1 GB heap of CRD schemas) → kind-up caps the control-plane node container at 2 CPUs (kind-only tuning; thresholds unchanged). Measured: burst seconds 5.4% → 2%; the healthy build was then promoted in 249 s.
- 2026-10-27: The release demos commit and revert, so they ran on a local throwaway branch (demo/phase-2-releases, never pushed). The branch is kept; deleting branches is the owner's call.
- 2026-10-27: The kind-up procedure changed (control-plane cap) → one more fresh `make kind-up` so all Phase 2 evidence comes from a single run (pre-approved: recreating the kind cluster).
- 2026-10-27: The run needed one manual step (the Prometheus operator started before its CRDs existed, slower with the control-plane cap) → Prometheus Operator CRDs became their own earlier Argo CD app (prometheus-operator-crds 32.0.1 = operator v0.94.1), then one more fully unattended fresh run so the published evidence has no manual intervention (pre-approved: recreating the kind cluster).
- 2026-10-27: The unattended evidence run (fresh cluster 15:06 UTC) passed kind-up, e2e, netpol, policies and rotation, but the healthy-release canary was aborted on p95 during a one-minute system-wide slowdown (stable pods and the ledger slowed down alike). → I stopped the run (its next step would have waited 15 min on the aborted rollout), reverted the demo's commit and retried the release demos (attempt 2 of 3 allowed), with PostgreSQL slow/lock-wait logging and a session sampler switched on temporarily (kind only, reset afterwards). Attempt 2 passed both demos. The sampler showed WAL fsync stalls (`WALWrite`, commits 500–730 ms) while the demo built and pushed the image, the most likely cause of attempt 1. Thresholds unchanged; attempt 1 is published as evidence.
- 2026-10-27: Follow-up, not blocking: kind-up still generates an unused `fincore-ledger-db` emulator secret (Phase 1 leftover; nothing consumes it). Left as is so kind-up matches the evidence run; remove in Phase 3.
- 2026-10-28: Portfolio images (owner request) → the architecture diagram is hand-laid-out as 4:3 SVG with the same nodes, flows and labels as docs/architecture.md (Mermaid's automatic layouts were unreadable at 4:3). The Argo CD app tree is rendered from live Argo CD API data, plus a real UI screenshot with the 23/23 counters, because the native tree cannot show 22 child apps legibly. The policy and rotation images are rendered from the committed evidence logs. Each image's provenance is in docs/img/README.md.
- 2026-10-28: The bad-release capture needs Argo CD to follow a commit, and a detached HEAD did not resolve through the in-cluster git server → a local branch `demo/portfolio-shots` (bad release + revert, never pushed) is kept; deleting branches is the owner's call.

## Waiting for owner

(nothing)
