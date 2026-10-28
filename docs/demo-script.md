# Demo script (3–5 minutes, screen recording)

What to show, in what order, and what to say. Everything runs on the laptop (kind). Prepare it first; nothing below waits on a slow step during the recording.

## Before recording (10 minutes, off camera)

```bash
make kind-up                       # ~17 min from nothing, or reuse a running cluster
export KUBECONFIG=$PWD/.kube/kind-config
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 &
kubectl -n argocd port-forward svc/argocd-server 8081:80 &
kubectl argo rollouts dashboard &  # http://localhost:3100
```

Open three browser tabs: **Grafana** → FinCore folder, **Argo CD** (http://localhost:8081), **Argo Rollouts** (http://localhost:3100). Use a terminal with a large font. Let the traffic generator run 5 minutes so the dashboards have history.

## 1. What it is (30 s): README, first screen

> "FinCore is a payment platform built the way a regulated fintech would run it on AWS: EKS, GitOps, canary releases that roll themselves back, a double-entry ledger, and a cardholder-data zone isolated like PCI DSS asks. Everything you'll see runs on my laptop in kind, from the same manifests the AWS environment uses."

Show the architecture image and the headline numbers.

## 2. A payment, end to end (60 s): Grafana

1. **FinCore / Business**: payments per second, capture rate, money moved, **ledger imbalance: 0**.
   > "Every payment is a balanced double entry, enforced by the database itself. This number must always be zero."
2. Run `make demo-observability` in the terminal: one payment followed from its trace to its logs to its ledger entry. Then in Grafana → Explore → Loki, paste the trace id from the output, open the log line → **Open trace** (Tempo).
   > "One request, across two services, with its logs and its ledger entry, from a single id."

## 3. A bad release rolls itself back (60 s): Argo Rollouts

```bash
make demo-bad-release              # commits a build where half the requests fail, then reverts
```
Switch to the Rollouts dashboard: the canary takes 10 % of the traffic, analysis runs, and the rollout is **aborted** within about two minutes, with traffic back on the stable version.
> "Nobody pressed a button. The canary was measured against the SLO, failed, and every request went back to the good version."

## 4. Security in the zone (45 s): terminal

```bash
make demo-policies                 # 11 admission cases
```
Point at three lines: unsigned image rejected, root container rejected, the signed one admitted **by digest**. Then:
```bash
make demo-netpol                   # a pod outside the zone cannot reach the ledger
```
> "What can run in the cardholder-data zone, and what can talk to it, is decided by policy, not by convention."

## 5. Failure and recovery (60 s): Grafana, FinCore / SLOs

Show `docs/evidence/phase-3/chaos.md` and the SLO dashboard from the chaos run: the zone loss, the page that fired, the recovery, the error budget it cost.
> "We kill pods, drain nodes, restart the database and lose a whole zone, and measure what users saw."

Then `docs/evidence/phase-3/dr-drill.md`:
> "Here we deleted the entire cluster while payments were flowing, and rebuilt it from backups: ledger balanced, Vault back with its data, payments flowing again, with the RTO and RPO measured."

## 6. What it costs, how it's run (30 s)

`docs/cost.md` headline: cost per hour, per day, per 1,000 payments, and the Spot share. Then the ADR index and the runbooks folder.
> "Every number has its source, every decision has an ADR, and every alert has a runbook."

## After recording

`make kind-down` (keeps the registry and the backup store), or `PURGE=1 make kind-down` for everything.
