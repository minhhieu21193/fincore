# Portfolio entry

## Title (≤ 70 characters)

**Production-grade payments on AWS EKS: GitOps, canary, PCI zone**

(62 characters)

## Description (≤ 600 characters)

Payment platform built like a regulated fintech runs one: a double-entry ledger enforced by the database, an isolated cardholder-data zone (signed images only, default-deny network, per-pod Vault database users), and canary releases that roll themselves back on SLO metrics. GitOps with Argo CD, Grafana/Loki/Tempo, burn-rate alerts. Chaos-tested; the whole cluster restored from backups in 18 min (RPO under 9 min); AWS costs from public price lists.

## Skills (5)

1. Kubernetes (Amazon EKS)
2. Terraform
3. GitOps (Argo CD, Argo Rollouts)
4. Site Reliability Engineering (SLOs, observability, chaos, DR)
5. Cloud security / PCI DSS (Vault, Kyverno, network isolation)

## Thumbnail

`docs/img/architecture-cde.png`: the cardholder-data zone and every allowed flow. It reads well at small size; the dark zone boundary is the hook.

## Proof captions (one per screenshot)

1. **`docs/img/bad-release-rollback.png`**: "A deliberately bad release, caught by its own canary and rolled back automatically within about two minutes. Nobody touched it."
2. **`docs/img/admission-policies.png`**: "11 admission tests against the live cluster: unsigned, unattested, root and off-zone workloads are rejected; the signed one is admitted by digest."
3. **`docs/evidence/phase-3/grafana-slo-chaos.png`**: "Chaos run: pods killed, a node drained, the database restarted, a whole zone lost. Burn-rate alerts paged, then resolved; the ledger stayed balanced."
