# Database failover

AWS: Aurora PostgreSQL (Serverless v2), a writer and a reader in different AZs. A failover promotes the reader, typically in under a minute; the cluster endpoint follows. kind: a single PostgreSQL pod; a restart is the closest equivalent.

**What the services do:** payments-api and the ledger lose their connections. In-flight requests fail with 503 (`57P03 the database system is not yet accepting connections`, `connection refused`), and new connections succeed once the writer is back. Nothing needs a restart: pools reconnect (`DB_HEALTH_CHECK_PERIOD`). A client that retries a failed payment with the same `Idempotency-Key` gets exactly one payment. Events wait in the outbox and are published when the database is back.

## Planned failover (AWS)

```
aws rds failover-db-cluster --db-cluster-identifier <name> --target-db-instance-identifier <reader>
```
Announce it, watch FinCore / SLOs during it; expect a burst of 503s lasting as long as the failover, and no page (the 1 h / 5 m burn-rate pair needs a longer burn). `scripts/chaos-aws.sh` runs it as an experiment.

## Unplanned

1. `aws rds describe-events --source-type db-cluster --duration 60` (AWS) or `kubectl -n fincore-data get pod postgres-0` (kind): restarted, OOM-killed (`kubectl describe`), failed over?
2. FinCore / Business: payments recovering? Outbox backlog draining?
3. If errors persist after the database is back: the ledger pods' Vault-issued users may have expired during the outage. Vault Agent renders a new one; check `kubectl -n fincore-cde logs <ledger pod> -c vault-agent`.

## Slow, not down

Sessions waiting on `LWLock:WALWrite` / `IO:WalSync` mean commits are queuing on WAL flushes; `IO:DataFileRead` means reads from disk.
```
kubectl -n fincore-data exec postgres-0 -- psql -U postgres -c "select usename, state, wait_event_type, wait_event, now()-query_start as running, left(query, 60) from pg_stat_activity where state <> 'idle' order by running desc nulls last limit 15"
```
A query that runs on every replica and grows with the data is the first suspect (postmortem 2026-10-28). Connection count must stay within the budget: pods × `DB_MAX_CONNS` ≤ 100.

## After

- Ledger imbalance 0, outbox backlog 0.
- Compare payments created during the window with ledger transactions (`/v1/transactions/payment:<id>:capture` for a sample).
