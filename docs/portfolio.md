# Portfolio entry

## Title (≤ 70 characters)

**Production-grade payments on AWS EKS: GitOps, canary, PCI zone**

(62 characters)

## Description (≤ 600 characters)

FinCore is a payment platform built the way a regulated fintech runs one. It has a double-entry ledger enforced by the database and an isolated cardholder-data zone: signed images only, default-deny network, and per-pod database credentials from Vault. Releases are canaries that roll back by themselves when the SLO metrics drop. Everything is GitOps (Argo CD), observable (metrics, logs, traces, SLO burn-rate alerts), load-tested, chaos-tested, and restored from backups with measured RTO/RPO. Every AWS cost comes from public price lists.

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
3. **`docs/img/credential-rotation.png`**: "Vault issues each ledger pod its own short-lived database user. Rotation happens under live traffic with 0 errors and 0 restarts."
