# Chaos experiments on kind

Run 2026-10-28 20:05 UTC. Each experiment: 60 s baseline, the fault, recovery, then 120 s; the measurement window runs from 10 s before the fault to the end of those 120 s.
Client = a k6 probe sending 5 payments/s from a node the experiments do not touch (status 0 = no answer within 5 s).
Server = payments-api's own metrics in Prometheus. Budget = share of the 30-day 0.1 % error budget the window consumed, at the probe's failure rate.

| Experiment | Fault | Client availability | Longest client-visible outage | Client p99 | Server 5xx / requests | Server max p99 | Budget burned | Ledger balanced | Outbox drained |
|---|---|---:|---:|---:|---:|---:|---:|:---:|:---:|
| pod-kill | 1 s | 100 % | 0.0 s | 1564 ms | 1 / 1902 | 2352 ms | 0 % | yes | yes |
| node-drain | 214 s | 95.35 % | 7.0 s | 413 ms | 249 / 3970 | 1058 ms | 0.63 % | yes | yes |
| db-restart | 14 s | 95.67 % | 6.4 s | 4996 ms | 62 / 2094 | 5000 ms | 0.24 % | yes | yes |
| zone-loss | 241 s | 37.28 % | 242.8 s | 5004 ms | 380 / 2419 | 5000 ms | 9.29 % | yes | yes |

## What happened

**pod-kill** (20:31:49 UTC): killed payments-api-74675f959-jvhsz and ledger-bfc979bdb-2l62g (no grace period).

**node-drain** (20:34:59 UTC): drained fincore-worker (zone a): 21 pods evicted, drain exit code 1; pending while the node was cordoned: argocd/argocd-application-controller-0 vault/vault-0 ; uncordoned after 214s.

**db-restart** (20:41:45 UTC): postgres-0 deleted and ready again after 14s.

**zone-loss** (20:45:02 UTC): zone c frozen (docker pause fincore-worker3: payments-api and ledger, the whole CDE) for 240s; zone c back; CDE ready 13s after the node returned.

Events across the whole run: 35394 published from the outbox, 35361 received by the notifier.

## Alerts

| Alert | Severity | First seen | Firing from | Last seen | Receiver | |
|---|---|---|---|---|---|---|
| PaymentsAvailabilityBudgetBurn | ticket | 20:30:49 | 20:30:49 | 21:19:53 | ticket | inhibited at times |
| PaymentsLatencyBudgetBurn | ticket | 20:30:49 | 20:30:49 | 21:19:53 | ticket |  |
| PaymentsAvailabilityBudgetBurn | page | 20:40:13 | 20:40:13 | 21:19:23 | page |  |
| LedgerUnavailable | page | 20:47:05 | 20:47:05 | 20:49:23 | page |  |
| PaymentsAPIUnavailable | page | 20:47:05 | 20:47:05 | 20:49:23 | page |  |

Every page resolved by 21:19:46 UTC.
Tickets still open at the end (slow-burn by design, 2 h / 6 h short windows): PaymentsAvailabilityBudgetBurn, PaymentsLatencyBudgetBurn.

Experiment times (UTC): pod-kill 20:31:49-20:31:50, node-drain 20:34:59-20:38:42, db-restart 20:41:45-20:41:59, zone-loss 20:45:02-20:49:16.
Files: `chaos-results.json`, `chaos-alerts.tsv` (every Alertmanager poll), `chaos-probe.log` (every probe request).
