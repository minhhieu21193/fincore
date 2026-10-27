# Phase 3 plan: reliability, observability, cost

Goal: the proof. FinCore is observable end to end (metrics, logs, traces, SLOs with burn-rate alerts), its limits are measured (load test), its failure modes are exercised (chaos, with postmortems), it can be restored into a new cluster with measured RTO/RPO, and its cost is known. The client-facing docs (ADRs, runbooks, demo script, portfolio, a README written as a case study) complete the project.

As in Phases 1 and 2, everything is proven on `kind`. AWS-only parts (AWS FIS, Aurora failover and snapshots, real cost, `up.sh`/`down.sh`) are written and statically checked, never run.

## Acceptance criteria (how they are checked)

The brief lists deliverables for Phase 3 but no acceptance line, so each deliverable becomes a check that can be run on kind:

| # | Criterion | Command | Evidence (`docs/evidence/phase-3/`) |
|---|---|---|---|
| C1 | Observability works end to end: Grafana has a platform, a per-service RED and a business dashboard (payments/s, success rate, ledger imbalance = 0); logs are in Loki; traces are in Tempo; a log line links to its trace | `make demo-observability` | Dashboard screenshots; a payment followed from its trace to its log lines to its ledger entry |
| C2 | SLOs with multi-window burn-rate alerts: 99.9% of payments succeed, 99% of payments under 300 ms. Alerts fire on a real incident and resolve after. | `make check` (`promtool test rules`), C4 | Rule tests; the alert timeline during the chaos run |
| C3 | Load test: k6 ramp towards 300 RPS sustained. If kind cannot hold it within the SLOs, the highest sustained rate is measured and published, not faked. | `make loadtest-report` | RPS, p50/p95/p99, error rate, replicas over time |
| C4 | Chaos, with SLO impact shown on the dashboards: kill pods, drain a node, lose a zone (cordon + drain every node of one zone), restart the database (failover on AWS). Two blameless postmortems. | `make chaos` | Per-experiment availability, latency and error budget burn; `docs/postmortems/` |
| C5 | DR drill: back up, destroy the cluster, restore into a fresh one. Ledger balanced, Vault unsealed with its data, payments flowing. RTO and RPO measured. | `make dr-drill` | Timeline, RTO/RPO, ledger and payment counts before and after |
| C6 | Cost: OpenCost on kind; `docs/cost.md` with AWS hourly/daily cost, assumptions, Spot share and cost per 1,000 payments; `scripts/up.sh` / `scripts/down.sh` (ordered destroy) with a leftover check | `make check` (static only, never run) | `docs/cost.md` |
| C7 | Docs: README as a case study (architecture image and 4–5 headline numbers on the first screen), `docs/architecture.md`, 5 ADRs (plus "considered, not chosen"), 5 runbooks, `docs/demo-script.md`, `docs/portfolio.md` | review | the files |
| C8 | Phase 1 and 2 still hold, and every static check is green | `make e2e`, `make check` | logs |

## Components and versions (checked 2026-10-28)

| Component | Version | Notes |
|---|---|---|
| Grafana | bundled with kube-prometheus-stack 92.13.1 (chart 14.0.1, `grafana-community`) | Dashboards and datasources as code (sidecar ConfigMaps) |
| Alertmanager | bundled with kube-prometheus-stack | Turned on for the SLO alerts; the receiver is a webhook to the demo sink on kind |
| Loki | chart 20.0.2 / app 3.7.9 (`grafana-community`, OCI) | Single binary, filesystem storage, 48 h retention on kind |
| Tempo | chart 3.2.1 / app 3.1.1 (`grafana-community`, OCI) | Monolithic. The services already export OTLP; they send it straight to Tempo, with no collector. |
| Fluent Bit | chart 0.58.3 / app 5.1.3 | Ships container logs to Loki, lighter than an Alloy agent on every node |
| OpenCost | chart 2.5.33 / app 1.121.3 | Reads Prometheus; custom pricing on kind |
| Velero | chart 12.2.1, Velero 1.18.4, AWS plugin 1.14.4 | Cluster state and secrets |
| SeaweedFS | 4.51 (S3 gateway) | The S3 bucket on kind, run as a container outside the cluster so it survives the drill. MinIO's community edition is archived (source-only). |
| k6 | 2.3.0 (pinned image) | In-cluster load generator |

## Design notes

- **SLIs:**
  - availability = `POST /v1/payments` answered without a 5xx (declines are correct answers);
  - latency = share under 300 ms (the `le="0.3"` bucket).
  
  Alerts follow the multi-window, multi-burn-rate pattern from the Google SRE workbook (14.4× over 1 h and 5 m, 6× over 6 h and 30 m page; 3× and 1× ticket). Recording rules and alerts are tested with `promtool`.
- **Business dashboard.** Payments per second by outcome, success rate, captured volume, outbox lag, DLQ depth, and the ledger's live imbalance (must be 0).
- **Tracing.** payments-api → ledger is already instrumented (otelhttp). Loki derives `trace_id` from the JSON logs and links to Tempo; Tempo links back to the logs.
- **Load test.** Runs as an in-cluster k6 Job (a port-forward would be the bottleneck). It is allowed through the CDE NetworkPolicy by its own label and admitted by Kyverno as an approved, digest-pinned image.
- **Chaos on kind:** pod kills, a node drain, and zone loss by cordoning and draining. The single CDE node is itself a finding: on AWS the `cde` NodePool spans three AZs. DB failover is a PostgreSQL restart; on AWS `scripts/chaos-aws.sh` uses AWS FIS and `aws rds failover-db-cluster`.
- **DR:**
  - Velero backs up the cluster state that is not in git (secrets, including the KMS seed on kind);
  - PostgreSQL is dumped consistently (`pg_dump`, a CronJob to S3);
  - Vault is backed up with Raft snapshots through a dedicated Kubernetes-auth role (snapshot only).
  
  `kind-up.sh --restore` recreates the cluster, restores secrets and data before the services start, and GitOps recreates everything else. RTO is measured to the first successful payment, RPO as the age of the newest backup at the time of the disaster.
- **Cost.** AWS prices are taken from AWS's public price list for ap-southeast-1, with the source and date recorded and nothing guessed. Cost per 1,000 payments uses the measured sustained throughput.

## Work breakdown

1. Observability: Grafana, Loki, Fluent Bit, Tempo; OTLP from the services; dashboards; demo script.
2. SLO rules and alerts with `promtool` tests; Alertmanager routing.
3. Load test Job, report script, results.
4. Chaos experiments script; postmortems.
5. Backups (Velero, `pg_dump`, Vault snapshots) to SeaweedFS; restore path; DR drill script.
6. OpenCost; `docs/cost.md`; `scripts/up.sh` and `scripts/down.sh`.
7. Docs: ADRs, runbooks, demo script, portfolio, README case study.
8. Fresh unattended acceptance run; evidence; PR `phase-3` → `main`.

## Risks

| Risk | Mitigation |
|---|---|
| Memory: about 2.5 GB is free on the 10 GB VM (the maximum allowed without the owner) | Monolithic Loki and Tempo with small limits; Fluent Bit instead of Alloy; no OTel collector; short retention; Velero node agent not needed (consistent app-level backups instead of volume copies) |
| kind cannot sustain 300 RPS | Publish the measured maximum and why. The thresholds stay unchanged. |
| A restore depends on ordering (KMS seed before Vault, dumps before the services) | Explicit restore stage in `kind-up.sh` before Argo CD syncs the services; drill asserts the ledger invariant |
