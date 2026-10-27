# Phase 2 results: security and compliance

All acceptance criteria were verified on 2026-10-27 in one unattended run on a fresh cluster: `make kind-down && make kind-up`, then every demo in order and `make check`. Raw output is in [`docs/evidence/phase-2/`](evidence/phase-2/), and [`run-timeline.log`](evidence/phase-2/run-timeline.log) has the timeline.

Environment: Docker Desktop VM (6 CPU / 10 GB), kind 0.33.0, `kindest/node:v1.36.4`. The cluster has 1 control plane (capped at 2 CPUs), 2 general workers (zones `ap-southeast-1a/b`) and 1 tainted cardholder-data-zone worker (zone `c`). Why this shape: [decisions log](decisions-log.md) and the plan's [as-built section](plans/phase-2.md#as-built-deviations-from-this-plan-and-why).

`make kind-up` brought everything up unattended in 600 s ([log](evidence/phase-2/kind-up.log)), including the one-time Vault initialisation:
- recovery keys only, because of KMS auto-unseal;
- 3 Raft nodes unsealed by the local KMS emulator;
- the root token revoked once the configuration job's Kubernetes-auth role existed.

## B1: an unsigned image and a root container are rejected

`make demo-policies` ([log](evidence/phase-2/policies.log)). Every request is a real create against the API server; each rejection is asserted on its message.

| # | Request | Outcome | Rejected by |
|---|---|---|---|
| 1 | Pod with an **unsigned** image from our registry | rejected: *image is not signed by the FinCore release pipeline* | Kyverno `verify-fincore-images` |
| 2 | Signed image **without an SBOM attestation** | rejected: *image has no signed SBOM attestation (SPDX)* | Kyverno `verify-fincore-images` |
| 3 | A signed tag later **overwritten** with unsigned content | rejected (the signature binds the digest, not the tag) | Kyverno `verify-fincore-images` |
| 4 | Image from a **foreign registry** (`docker.io/library/nginx`) | rejected | Kyverno `restrict-image-registries` |
| 5 | **Root** container in a Deployment | rejected at the Deployment, before any pod exists (Pod Security would only have warned) | Kyverno `require-non-root` (autogen) |
| 6 | **Root** container as a bare Pod | rejected | Pod Security `restricted` (Kyverno also forbids it) |
| 7 | Writable root filesystem | rejected | Kyverno `require-read-only-root-fs` |
| 8 | No memory limit | rejected | Kyverno `require-resources` |
| 9 | Pod outside the zone tolerating the CDE taint | rejected | Kyverno `no-cde-tolerations-outside-zone` |
| 10 | CDE pod off the CDE nodes | rejected | Kyverno `cde-pods-on-cde-nodes` |
| 11 | Control: signed, SBOM-attested, compliant image | **admitted**, image rewritten to `payments-api:0.1.1@sha256:…` (the verified digest) | — |

The same policies are covered offline by 27 `kyverno test` cases in `make check`.

## B2: the ledger's database password rotates without a restart

`make demo-rotation` ([log](evidence/phase-2/rotation.log)), while the traffic generator posted 10 payments/s.

| Check | Result |
|---|---|
| Static ledger password in the zone | none. The `ledger` owner role cannot log in (`rolcanlogin = f`). |
| Rotation | both ledger pods moved to new Vault-issued users (`v-kubernet-ledger-…`, TTL 3 min), e.g. `…-1793114288 → …-1793114419` |
| Expired users | dropped from PostgreSQL by Vault (2 revoked) |
| Pods | same two pods before and after, **0 restarts** |
| Errors during the window (Prometheus) | ledger **940 requests, 0 5xx**; payments-api **980 requests, 0 5xx** |
| Application signal | `fincore_db_credential_changes_total` +2 |
| Audit | Vault's audit log shows each `read database/creds/ledger` by `fincore-cde/ledger` with its lease ID |

## B3: NetworkPolicy blocks a pod outside the zone

`make demo-netpol` ([log](evidence/phase-2/netpol.log)). A signed probe image (`tools/netprobe`) attempts TCP connections.

| From | To | Result |
|---|---|---|
| namespace `fincore` (outside the zone) | ledger, payments-api, PostgreSQL, queue | **BLOCKED** (no answer within 4 s) |
| namespace `fincore` | internet (control) | OPEN, so the probe and the network work and only the policy blocks |
| inside `fincore-cde`, a pod with no allow rule | internet, ledger, PostgreSQL | **BLOCKED** |
| traffic generator → payments-api → ledger → PostgreSQL / queue | — | payment **captured** |

## B4: Phase 1 still holds with all of the above switched on

| Check | Result |
|---|---|
| `make e2e` ([log](evidence/phase-2/e2e.log)) | passed. Capture, idempotent replay, balanced double entry, signed webhook, decline. The ledger runs on Vault-issued credentials across the zone boundary. |
| Bad build, 50% injected HTTP 500 ([log](evidence/phase-2/demo-bad-release.log)) | **aborted automatically** 139 s after the commit (the signed bad image was admitted, then the canary rejected it). Canary success rate measured 0.50 and 0.48 against a 0.99 threshold. |
| Healthy build ([log](evidence/phase-2/demo-good-release.log)) | promoted 10 → 30 → 60 → 100% in 281 s, with 12 successful measurements. Canary p95 0.15–0.30 s. |
| `make check` ([log](evidence/phase-2/check.log)) | all green: Go tests with PostgreSQL, golangci-lint, Terraform fmt/validate, tflint, checkov, helm lint, kubeconform (CRD schemas generated from the pinned charts), 27 `kyverno test` cases, actionlint, shellcheck |

**The healthy release needed a second attempt.** In the first attempt ([log](evidence/phase-2/demo-good-release-attempt-1-aborted.log), [AnalysisRun and Prometheus](evidence/phase-2/demo-good-release-attempt-1-analysis.txt)) the canary was aborted on p95 (0.20, 4.1, 3.7 s) while its success rate was 1.0. The cause was not the canary: stable pods slowed down the same way during the same minute, and ledger p95 reached 2.1 s.

Diagnostics on the retry ([PostgreSQL sessions](evidence/phase-2/postgres-sessions-during-releases.log)) showed commits taking 500–730 ms with sessions waiting on `WALWrite` while the demo built and pushed the release image. On the laptop, PostgreSQL's WAL fsyncs share one virtual disk with Docker. That is the most likely cause of attempt 1 too, though it was not instrumented. The retry is within the run's rules (up to 3 attempts), and the acceptance thresholds were not changed.

## Findings worth knowing

- **NetworkPolicy start-up window.** A brand-new pod is unrestricted for about a second until the policy engine programs it (measured on kind; the EKS VPC CNI's default "standard" mode behaves the same). The demo measures steady-state enforcement. Strict mode would close the window but needs policies for every platform namespace first ([compliance gaps](compliance-mapping.md#not-covered-gaps-a-real-assessment-would-raise)).
- **Canaries need connections that move.** payments-api's keep-alive pool to the ledger stayed pinned to old pods, so a ledger canary got no traffic. `httpx.Client` now recycles idle connections every 10 s (payments-api 0.1.1).
- **Admission control is a capacity question.** Verifying a signed image and its SBOM takes seconds on a busy node (two registry round trips per admission). The webhook timeout is 30 s, and Kyverno runs with reports off on small clusters.
- **A laptop is not a load-test rig.** Canary latency analysis, starved probes and WAL fsyncs all exposed laptop-VM limits; the [decisions log](decisions-log.md) records each fix. The AWS thresholds and values are unchanged.

## Not yet proven (by design)

- Nothing has been applied to AWS. The following are statically checked only:
  - WAF, CloudTrail, the KMS unseal key and its Pod Identity, the CDE NodePool and security groups (Aurora admits only CDE and system nodes), and VPC CNI enforcement;
  - Kyverno's keyless verification of `release.yml@main` signatures in ECR.

  They will be exercised on the owner's demo day.
- The `aws-ebs-csi-driver` and `eks-pod-identity-agent` add-on versions must be looked up in the account (`terraform.tfvars.example`).
