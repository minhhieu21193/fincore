# Phase 1 results: platform core

All three acceptance criteria were verified on 2026-10-26 on a fresh cluster: `make kind-down && make kind-up`, then `make e2e`, `make demo-good-release` and `make demo-bad-release`. Raw output is in [`docs/evidence/phase-1/`](evidence/phase-1/).

Environment: Docker Desktop VM (4 CPU / 8 GB), kind 0.33.0, `kindest/node:v1.36.4`, 1 control plane + 3 workers labelled with zones `ap-southeast-1a/b/c`.

## A1: a payment flows end to end

`make e2e` ([log](evidence/phase-1/e2e.log)). The path is payments-api → ledger → transactional outbox → ElasticMQ (SQS API) → notifier → signed webhook to the demo merchant.

| Check | Result |
|---|---|
| `POST /v1/payments` with `Idempotency-Key` | 201, `status=captured` |
| Same key, same body | byte-identical response, `Idempotent-Replayed: true`, no second charge or ledger posting |
| Same key, different body | 422 `idempotency_key_reused` |
| Ledger entries for the capture | Dr `assets:processor_receivable` 1999 / Cr `liabilities:merchant:…` 1942 / Cr `revenue:fees` 57 (debits = credits) |
| Merchant balance | 1942, derived from entries (no stored balance) |
| Whole-ledger invariant | `{"balanced":true,"imbalance_by_currency":{"USD":0}}` |
| Webhook | exactly one `payment.captured`, HMAC-verified by the receiver, delivered in under 1 s |
| Declined card | 402 `card_declined`, `payment.failed` webhook delivered, no ledger entries |

Beyond the end-to-end path, the database itself enforces the invariants, independently of the API. Raw SQL that bypasses the application is rejected for each of these: unbalanced, single-entry, zero-entry and mixed-currency transactions; UPDATE, DELETE or TRUNCATE on ledger tables; and illegal payment state transitions. See `services/ledger/internal/ledger/store_test.go` and `TestDatabaseRejectsIllegalTransition`. The 24 Go tests run against PostgreSQL 17 in CI.

## A2: a bad build rolls back automatically

Both demos go through GitOps, exactly as a real release does: build → commit the tag bump → Argo CD sync → Argo Rollouts canary. The background analysis queries Prometheus for **canary pods only** (`rollouts_pod_template_hash`). Thresholds: success rate ≥ 99% and p95 ≤ 300 ms. Missing data counts as inconclusive, never as pass or fail.

| | Healthy build ([log](evidence/phase-1/demo-good-release.log)) | Bad build, 50% injected HTTP 500 ([log](evidence/phase-1/demo-bad-release.log)) |
|---|---|---|
| Commit → canary pods running | 11 s | 17 s |
| Outcome | promoted 10 → 30 → 60 → 100% | **aborted automatically**, canary scaled to 0 |
| Time | 233 s to 100% | **109 s** from commit to abort |
| Canary success rate (measured) | 1.0 in 6 of 6 measurements | **0.47, 0.45**, so 2 failures > `failureLimit` 1 |
| Canary p95 (measured) | 0.147–0.148 s | 0.144–0.145 s (latency was fine; errors were not) |
| Stable during the event | n/a | untouched; 3/3 pods on `payments-api:0.1.0` |
| Back to git truth | revert → immediate switch back (`rollbackWindow`) | revert → Healthy on the stable version |

A first attempt (before the fix in commit `836302c`) also "rolled back", but for the wrong reason. The measurements were empty: k6 reused keep-alive connections that kube-proxy had pinned to the stable pods, so the canary received no traffic. Since that fix, the demo **fails itself** unless the abort is backed by measurements with data. The healthy-build demo shows the analysis has no false positives.

## A3: all static checks green

`make check` (`scripts/check.sh --all`; CI runs the same script):

| Check | Scope | Result |
|---|---|---|
| go vet, go test -race (PostgreSQL 17), golangci-lint v2 | all Go code | pass |
| terraform fmt / validate (1.17.0) | `terraform/bootstrap`, `terraform/envs/demo` | pass |
| tflint 0.65.0 (terraform + aws rulesets) | every root and module | pass |
| checkov 3.3.30 | Terraform, Dockerfiles, GitHub Actions | 0 failed; skips are justified inline |
| helm lint (Helm 4.3.1) | every local chart, kind and AWS values | pass |
| kubeconform 0.8.0, strict, K8s 1.36 + CRD schemas | **every Argo CD Application rendered as Argo CD would**: 251 resources (kind) and 276 (AWS) | 0 invalid |
| actionlint, shellcheck | workflows, scripts | pass |
| Trivy 0.76.1 (fixable HIGH/CRITICAL) | 4 service images | pass (after bumping `golang.org/x/net` for CVE-2026-78669) |

## Not yet proven (by design)

- Nothing has been applied to AWS. The Terraform is static-checked only. ALB weighted canary routing, Karpenter, Aurora, SQS and Pod Identity will be exercised on the owner's demo day.
- Load-test numbers, SLOs, chaos, DR and cost are Phase 3.
