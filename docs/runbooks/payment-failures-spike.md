# Payment failures spike

**Alerts:** `PaymentsAvailabilityBudgetBurn` (5xx), `PaymentsLatencyBudgetBurn` (> 300 ms), `PaymentsAPIUnavailable` / `LedgerUnavailable` (no instance reachable).
**SLOs:** 99.9 % of `POST /v1/payments` without a 5xx, 99 % under 300 ms (30 days). A *page* means the monthly budget runs out in days at this rate; a *ticket* means in weeks.

## 1. How bad, since when (2 minutes)

- Grafana → **FinCore / SLOs**: burn rate per window, answered payments by class, instances reachable.
- Grafana → **FinCore / Business**: payments/s by outcome. Declines (402) are normal; 5xx are not. Ledger imbalance must read 0 (if not: [ledger imbalance](ledger-imbalance.md) first).
- Did something change? `kubectl argo rollouts list rollouts -n fincore-cde` (a canary in progress?), Argo CD history, the change log.

## 2. Where it fails

| Look at | What it tells you |
|---|---|
| **FinCore / Service RED**, service `payments-api`, then `ledger` | Which service, which route, which version (a canary shows as a second version) |
| Its "Errors and warnings" panel (Loki) → open a line → **Open trace** | The failing call in Tempo: processor, ledger, database or queue |
| `kubectl -n fincore-cde get pods -o wide` | Restarts, `NotReady`, pods `Pending` (no CDE node: [node pressure](node-pressure.md)) |
| `kubectl -n fincore-cde logs -l app.kubernetes.io/name=payments-api --since=10m \| grep -v '"msg":"request"'` | Error messages, grouped by eye |

Typical causes and their signature:

| Signature | Cause | Go to |
|---|---|---|
| Only the canary's version fails | Bad release | [Canary rollback](canary-rollback.md) (the analysis normally aborts it on its own) |
| `connection refused`, `57P03 not yet accepting connections` | Database restarting or failing over | [Database failover](db-failover.md) |
| `ledger request ... Client.Timeout exceeded` | Ledger slow or down | RED dashboard for `ledger`; its logs; Vault (it needs Vault for DB credentials) |
| Every instance unreachable (`PaymentsAPIUnavailable`) | Zone or node loss, crash loop | `kubectl get nodes`; [node pressure](node-pressure.md) |
| p95 high, few errors, database sessions waiting on `WALWrite` | Database I/O saturated | [Database failover](db-failover.md) §"slow"; postmortem 2026-10-28 |

## 3. Mitigate

- Bad release: `kubectl argo rollouts abort <rollout> -n fincore-cde` (traffic returns to the stable version at once).
- Capacity: the HPA scales payments-api 3 → 12 and the ledger 2 → 8 on CPU. If they are at max and CPU-bound, raise `maxReplicas` in git. **Stay within the connection budget** (pods × `DB_MAX_CONNS` ≤ 100; see the comment in `gitops/apps/*/values.yaml`).
- Dependency down (processor, database): nothing to restart in FinCore. Payments fail fast with 503, and clients retry with the same `Idempotency-Key`, which is safe. Watch the dependency.
- Do **not** restart all pods at once. Readiness only gates the first start; a mass restart takes the API to zero.

## 4. After

- Outbox backlog back to 0 (Business dashboard): every captured payment's event was published.
- Ledger imbalance 0.
- Blameless postmortem if a page fired (`docs/postmortems/`).
