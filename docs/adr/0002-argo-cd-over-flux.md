# 0002. Argo CD with Argo Rollouts, not Flux with Flagger

**Status:** accepted (Phase 1)

## Context

Everything in the cluster comes from git, and releases must be canaries that roll back by themselves when the SLO metrics degrade. The same repository has to drive kind (offline, from a local git server) and EKS.

## Decision

- **Argo CD**, app-of-apps: one root Application renders the component catalogue (`gitops/bootstrap/app-of-apps`). Each environment only switches components on and injects its cluster facts. Sync waves order the platform: Velero, CRDs, controllers, policies, Vault, data, services.
- **Argo Rollouts** for payments-api and the ledger: canary 10 → 30 → 60 → 100 %, analysed against Prometheus (success rate ≥ 99 %, p95 ≤ 300 ms), aborted automatically.

## Alternatives

- **Flux + Flagger.** Equally GitOps and lighter (no UI server). But Flagger drives canaries through a mesh or an ingress controller, while Argo Rollouts can split by replica ratio (kind) or by ALB weights (AWS) without a mesh (ADR index: no mesh). Argo CD's UI and its sync and health views are what a client or an auditor can look at.
- **Helm/kubectl from CI.** It's push-based, so drift is never corrected and the cluster credentials have to live in CI.

## Consequences

- Drift is corrected (`selfHeal`), and each change is a commit (the audit trail).
- Argo CD costs memory: its application controller alone is given 1.25 Gi on kind (`gitops/bootstrap/argocd/values-kind.yaml`).
- Health checks must know every resource kind. A custom Lua check makes an Application healthy only when its children are, which is what makes sync waves wait.
- Runtime-mutated fields must be ignored explicitly: webhook CA bundles in Vault's injector and the Prometheus Operator. Missing one caused a sync loop (`decisions-log`, 2026-10-28).
