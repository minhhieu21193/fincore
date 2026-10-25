# Phase 1 plan: Platform core

Goal: a demo-able platform core. A payment flows end to end on `kind`, a bad build is rolled back automatically by Argo Rollouts, and every static check is green. The AWS side (Terraform, AWS-only add-ons, CI push to ECR) is written and statically validated. It is **never applied** in this phase.

## Acceptance criteria (how they are checked)

| # | Criterion | Command | Evidence |
|---|-----------|---------|----------|
| A1 | Payment flows API → ledger → outbox → SQS-compatible queue → webhook | `make e2e` (`scripts/e2e.sh`) | Script output: payment `captured`, balanced ledger entries, webhook received by the sink, idempotent replay returns the same body |
| A2 | Bad build is rolled back automatically | `make demo-bad-release` (`scripts/demo-bad-release.sh`) | Rollout goes to `Degraded` / aborted with `AnalysisRun` failed, stable ReplicaSet keeps serving, no manual step |
| A3 | All static checks green | `make check` | terraform fmt/validate, tflint, checkov, helm lint, kubeconform, go vet/test, golangci-lint, actionlint |

## Pinned versions (checked 2026-10-26)

| Component | Version | Why |
|---|---|---|
| Kubernetes (EKS / kind node) | 1.36 / `kindest/node:v1.36.4` | 1.37 is brand new on EKS. 1.36 is supported by every add-on below (Karpenter ≥ 1.13). |
| Terraform | 1.17.0 | Latest stable. Uses S3-native state locking (`use_lockfile`), so no DynamoDB table. |
| AWS provider | 6.70.0 | Latest. Required by the 6.x / 21.x modules. |
| terraform-aws-modules vpc / eks / rds-aurora | 6.7.3 / 21.29.0 / 10.4.1 | Latest stable |
| Karpenter | 1.15.1 | Supports K8s 1.36 and 1.37 |
| Argo CD chart / app | 10.11.1 / v3.5.6 | |
| Argo Rollouts chart / app | 2.43.8 / v1.10.1 | |
| cert-manager | v1.21.3 | |
| External Secrets | 2.14.0 | |
| metrics-server chart | 3.14.0 (app 0.9.0) | |
| kube-prometheus-stack | 92.13.1 | Needed now as the canary-analysis metrics source. Phase 3 extends it. |
| AWS Load Balancer Controller | 3.6.2 | AWS only |
| ExternalDNS chart | 1.23.0 | AWS only |
| Go | 1.27.3 | |
| PostgreSQL | 17 (Aurora PostgreSQL 17 / `postgres:17.x-alpine` locally) | Same major version in both environments |
| ElasticMQ | 1.7.1 | SQS-compatible queue on kind (redrive and DLQ supported) |
| k6 | 2.3.0 | |

Images are pinned by tag **and** digest in manifests.

## What runs where

| Concern | AWS (`envs/aws`) | kind (`envs/kind`) |
|---|---|---|
| Database | Aurora PostgreSQL Serverless v2 | `postgres` StatefulSet |
| Queue | SQS + DLQ (redrive 5) | ElasticMQ with the same queue names and redrive |
| Secrets source | AWS Secrets Manager → External Secrets | K8s "secrets emulator" namespace → External Secrets (kubernetes provider). The ExternalSecret manifests are identical. |
| Ingress / DNS / TLS | ALB controller + ExternalDNS + cert-manager | port-forward. cert-manager with a self-signed issuer. |
| Nodes | System managed node group + Karpenter (Spot and on-demand NodePools) | 1 control-plane + 3 workers labelled with zones a/b/c |
| Images | ECR, pushed by CI | `docker build` + `kind load` |
| Git source for Argo CD | GitHub repo | In-cluster read-only git HTTP server over the bind-mounted local repo, so local commits sync without a remote |
| Canary traffic split | ALB weighted target groups (Rollouts `trafficRouting.alb`) | Replica-weighted canary (no traffic router) |

## Work breakdown (one commit or more each)

1. **Services (Go, `services/`)**: one Go module per service, plus a small shared `pkg/` module (logging, metrics, tracing, http middleware, migrations, health).
   - `payments-api`: `POST /v1/payments` with a required `Idempotency-Key` (request hash, replay, 409 while in flight, 422 on key reuse with a different body, stale-lock takeover). State machine `pending → authorized → captured | failed`, enforced in code (transition table) and in SQL (guarded `UPDATE ... WHERE status = $from` plus a CHECK). It uses a fake card processor with configurable latency and failure rate, calls ledger synchronously on capture (idempotent on payment id), and writes a transactional outbox row in the same transaction as the state change. An outbox relay (`FOR UPDATE SKIP LOCKED`, safe with N replicas) publishes to SQS. `GET /v1/payments/{id}`. Fault injection is **compiled in** via ldflags (`-X ...faultRate=0.5`) for the bad build.
   - `ledger`: double-entry ledger. `accounts`, `transactions` (unique `external_ref`), and `entries` (immutable, amount > 0). A **deferred constraint trigger** rejects any transaction whose debits ≠ credits at commit. Balances are derived by `SUM`, with no mutable balance column. `POST /v1/transactions`, `GET /v1/accounts/{code}/balance`, and the `ledger_imbalance` gauge.
   - `notifier`: long-polls SQS and POSTs an HMAC-signed webhook with retries and backoff. On failure the message is not deleted, so SQS redelivers it and after `maxReceiveCount` moves it to the **DLQ**. A `webhook-sink` binary (demo merchant endpoint) records the deliveries it receives.
   - Each service: OpenAPI 3.1 spec (`api/openapi.yaml`), `slog` JSON logs, Prometheus RED metrics, OpenTelemetry tracing (OTLP exporter enabled only when the endpoint is set; Tempo arrives in Phase 3), `/healthz` + `/readyz`, graceful shutdown, distroless non-root image.
   - Tests: unit tests (state machine, idempotency hashing, HMAC, retry) plus Postgres-backed tests (balanced-entry constraint, idempotent replay) that run against `TEST_DATABASE_URL` (a docker Postgres locally, a service container in CI).
2. **Helm chart `gitops/charts/fincore-service`**: Deployment **or** Rollout (canary 10→30→60→100 with background analysis), Service, HPA (targets the Rollout), PDB, topology spread (zone + hostname), probes, requests/limits, restricted securityContext, PodMonitor (relabels the `rollouts-pod-template-hash` so analysis can isolate the canary), ExternalSecret, optional ALB Ingress, and an AnalysisTemplate (success rate ≥ 99% and p95 < 300 ms, read from Prometheus).
3. **GitOps (`gitops/`)**: `bootstrap/app-of-apps` Helm chart renders one Argo CD `Application` per enabled component from `values-kind.yaml` / `values-aws.yaml`. Cluster-specific values (account ID, role ARNs, cluster name, domain) are injected at bootstrap time and **never committed**. Components: argo-rollouts, metrics-server, cert-manager, external-secrets, kube-prometheus-stack (lean), aws-load-balancer-controller and external-dns (AWS only), Karpenter + NodePools (AWS only), local-infra (kind only: postgres, elasticmq, secrets emulator, git server), fincore apps (payments-api, ledger, notifier, webhook-sink, db-init job, k6 traffic generator on kind).
4. **Terraform (`terraform/`)**: `bootstrap` (S3 state bucket: KMS, versioning, TLS-only, public access blocked) and `modules/{network,eks,karpenter,aurora,queues,ecr,kms,budget,github-oidc,secrets}`. `envs/demo` composes them: VPC across 3 AZs, private nodes, single NAT (cost), VPC endpoints (ECR api/dkr, S3, STS, SQS, Secrets Manager); EKS 1.36 with a managed system node group (tainted for critical add-ons) and Pod Identity; Karpenter IAM and interruption queue; Aurora Serverless v2; SQS + DLQ (KMS); ECR (immutable tags, scan on push); Budgets alert; GitHub OIDC deploy role scoped to repo and branch; Argo CD bootstrap via Helm with cluster values passed in. Default region `ap-southeast-1`, with `backend.hcl.example` for partial backend config.
5. **CI (`.github/workflows/`)**: `ci.yml` runs on PR/push: Go vet/test (Postgres service), golangci-lint, static checks, and a per-service docker build matrix plus Trivy (fail on fixable HIGH/CRITICAL). `release.yml` runs on `main`: OIDC → ECR push → `yq` bumps the tag in `gitops/envs/aws/apps/*.yaml` → commit → Argo CD syncs. Steps that need AWS are skipped when the repo variable `AWS_DEPLOY_ROLE_ARN` is not set, so the public repo stays green without an AWS account. Actions are pinned by commit SHA.
6. **Local scripts**: `scripts/kind-up.sh` (cluster, images, Argo CD, root app, generated secrets), `scripts/kind-down.sh`, `scripts/build-images.sh`, `scripts/e2e.sh`, `scripts/demo-bad-release.sh`, `scripts/check.sh`, plus a `Makefile` front-end.
7. **Docs**: `README.md` (Phase 1 quick start and verification commands) and `docs/phase-1-results.md` (actual acceptance output).

## Bad-release demo flow
1. `build-images.sh --bad` builds `payments-api:<sha>-bad` with `faultRate=0.5` baked in and loads it into kind.
2. The script bumps the image tag in `gitops/envs/kind/apps/payments-api.yaml` and commits. Argo CD syncs and the Rollout starts the canary at 10%.
3. The k6 traffic generator keeps ~10 rps flowing. The background AnalysisRun measures canary-only success rate and p95, the first failed measurement fails the run, and Rollouts aborts and scales the canary to 0. Stable keeps 100%.
4. The script asserts the abort, then `git revert`s the bump. The demo runs on a throwaway branch so that phase-1 history stays clean.

## Out of scope for Phase 1 (later phases)
Vault, Kyverno, cosign/SBOM, NetworkPolicies/CDE zone, WAF (Phase 2). Grafana/Loki/Tempo dashboards, SLOs, load test results, chaos, Velero, OpenCost, `up.sh`/`down.sh`, merchant dashboard page (Phase 3). ADRs and the case-study README come with their phases.

## Risks
- Laptop resources (Docker VM: 4 CPU / 8 GB): Prometheus is trimmed (no Grafana, no Alertmanager, 6h retention) and requests are kept small.
- Argo CD reads only committed content, so each local change must be committed before it syncs.

## As built: deviations from this plan and why

| Plan said | Built | Why |
|---|---|---|
| System node group "tainted for critical add-ons" | **Labelled** `fincore.io/node-role=system`, not tainted. Karpenter is pinned to it with a nodeSelector. | Argo CD sync waves wait for each wave to be Healthy. With a taint, every wave −10 add-on would stay Pending until Karpenter's NodePools (wave −5) existed, which is a deadlock. |
| Image tags in `gitops/envs/kind/apps/*.yaml` | `gitops/envs/<env>/values/<component>.yaml` | One convention for every component (add-ons and services). |
| Canary analysis: "first failed measurement fails the run" | `failureLimit: 1` (two failed measurements abort), **no data = inconclusive** (`inconclusiveLimit: 4`) | The first demo run aborted on *empty* measurements. The canary got no traffic because k6 reused keep-alive connections that kube-proxy had pinned to stable pods, so the rollback was right for the wrong reason. Now missing data can never pass or fail a release, and the demo asserts that the abort is backed by measured values. |
| Traffic generator | Opens a new connection per request (`noConnectionReuse`) | Same root cause. ALBs balance per request, so this matches production. |
| — | `rollbackWindow: 3` on Rollouts | Reverting to a recent revision switches back immediately, without walking the canary again. |
| Helm 3 implied | Helm **4.3.1** pinned locally (`.tools/bin`) and in CI | Current stable. The scripts use a hermetic repo config (`.tools/helm`), so the user's global Helm repos are never read or modified. |
| `checkov` via Homebrew | checkov 3.3.30 in a Python 3.13 venv under `.tools/` | The Homebrew build (Python 3.15) fails to load `pyexpat` on this macOS. |
| `tflint` via Homebrew | Release binary 0.65.0, checksum-verified, in `.tools/bin` | No longer in Homebrew core. |
| Trivy action in CI | Trivy CLI 0.76.1, pinned and checksum-verified (`scripts/ci/install-trivy.sh`) | Avoids depending on a third-party action's mutable tags. |
| kind git source | In-cluster read-only smart-HTTP git server (`tools/gitserver`, ~100 lines) over the bind-mounted `.git`. Argo CD tracks `HEAD`. | Argo CD can sync local commits with no remote. No Gitea or registry is needed, and nothing is pushed anywhere. |
| — | Bumped `golang.org/x/net` to v0.60.0 | Trivy flagged CVE-2026-78669 (HTTP/2 SETTINGS flood, HIGH, fixable). The CI gate would have failed. |

Not verifiable without AWS (documented, not guessed):
- The `eks-pod-identity-agent` add-on version has no public table. `terraform.tfvars.example` says how to look it up. The other three add-on versions come from the EKS user guide for 1.36.
- Terraform is `validate`d, `tflint`ed and `checkov`ed, but never planned against a real account. `allowed_account_ids` makes a wrong-account apply impossible.
