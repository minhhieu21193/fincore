# Portfolio images

All images are 1600×1200 PNG (4:3), captured with headless Chrome on 2026-10-27/28 from the kind cluster or the committed evidence. Every number in them comes from a live system or an evidence log; nothing is mocked.

| Image | What it shows | How it was made |
|---|---|---|
| `architecture-cde.png` | The cardholder-data zone boundary and every allowed flow | The diagram from [`docs/architecture.md`](../architecture.md), with the same nodes, flows and labels, hand-laid-out as SVG for 4:3. Mermaid's automatic layouts are 3:1 or 1:2 for this graph, which is unreadable as a thumbnail. |
| `argocd-apps.png` | The Argo CD app-of-apps: root plus 23 applications by sync wave, all Healthy and Synced | Rendered from live data of the Argo CD API (`/api/v1/applications`). Argo CD's own tree view cannot show 22 child applications legibly in 4:3. |
| `argocd-ui.png` | The real Argo CD UI (applications list), with the counters Synced 23 / Healthy 23 / Sync OK 23 | Screenshot of the Argo CD UI on kind |
| `bad-release-rollback.png` | A bad build aborted automatically by the canary analysis | A real Argo Rollouts dashboard screenshot taken in the aborted state (a fresh `deploy-kind.sh payments-api … --fault-rate 0.5`, reverted afterwards). The figures above it come from the same rollout: canary ReplicaSet creation to `RolloutAborted`, and the AnalysisRun values. |
| `admission-policies.png` | The 11 admission cases: 10 rejected with the API server's reason, 1 admitted by digest | Rendered from [`docs/evidence/phase-2/policies.log`](../evidence/phase-2/policies.log) |
| `credential-rotation.png` | Vault-issued PostgreSQL users rotating per ledger pod, with 0 errors and 0 restarts | Rendered from [`docs/evidence/phase-2/rotation.log`](../evidence/phase-2/rotation.log). Issue times come from the users' names; the drops at the 3-minute expiry match Vault's revocation log. |
