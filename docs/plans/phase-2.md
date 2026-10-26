# Phase 2 plan: Security and compliance

Goal: the fintech differentiator.
- A PCI-DSS-style cardholder-data zone (CDE) with its own nodes and default-deny networking.
- Database credentials for the ledger that Vault issues per pod and rotates without restarts.
- Admission policies that only let signed, SBOM-attested, non-root, read-only, resource-limited images from our registry into FinCore namespaces.
- Edge protection and audit trails on AWS.

Everything is proven on `kind`. The AWS side (WAF, CloudTrail, KMS auto-unseal, CDE NodePool, VPC CNI network policies) is written and statically checked but, as in Phase 1, **never applied**.

## Acceptance criteria (how they are checked)

| # | Criterion | Command | Evidence (`docs/evidence/phase-2/`) |
|---|---|---|---|
| B1 | An unsigned image and a root container are rejected | `make demo-policies` | `policies.log`. Each request is refused at admission with Kyverno's message: unsigned image, signed image without an SBOM attestation, image from a foreign registry, root container, writable root FS, missing limits, non-CDE pod tolerating the CDE taint. Control: a signed, compliant image is admitted, and its tag is rewritten to the verified digest. |
| B2 | The ledger's DB password rotates without a restart | `make demo-rotation` | `rotation.log`. Two consecutive Vault-issued PostgreSQL users (`v-kubernetes-ledger-…`) serve the ledger, and the expired user is dropped from `pg_roles`. Ledger `restartCount` is unchanged, and payments keep succeeding throughout (Prometheus: zero ledger 5xx in the window). |
| B3 | NetworkPolicy blocks a pod outside the zone | `make demo-netpol` | `netpol.log`. A pod outside the CDE cannot reach the ledger or PostgreSQL (connection times out). A CDE pod cannot reach the internet. The legitimate path (payments-api → ledger) still works. |
| B4 | Phase 1 still holds with all of the above switched on | `make e2e`, `make demo-bad-release`, `make check` | `e2e.log`, `demo-bad-release.log`, `check.log`. The payment still flows across the zone boundary, the signed bad build still rolls back automatically, and every static check is green, including the new policy tests. |

All four are run from a fresh `make kind-down && make kind-up`.

## Pinned versions (checked 2026-10-26)

| Component | Version | Notes |
|---|---|---|
| HashiCorp Vault | 2.2.1 (`hashicorp/vault`, by digest) | Latest stable. The 2.x breaking changes don't affect this design: no wildcard templated policy paths, no IPC_LOCK in the image. |
| Vault Helm chart / vault-k8s injector | 0.34.1 / 1.7.6 | The chart defaults to Vault 2.0.4; the image is overridden to 2.2.1. |
| Kyverno chart / app / CLI | 3.9.2 / v1.19.2 / v1.19.2 | Uses the CEL-based `policies.kyverno.io/v1` `ValidatingPolicy` and `ImageValidatingPolicy`. Kyverno 1.19 now warns that the legacy `kyverno.io` `ClusterPolicy` is deprecated, so it isn't used. |
| cosign | v3.1.4 | Signs locally with a generated key. CI signs keyless with GitHub OIDC (Fulcio + Rekor). |
| Syft | v1.55.0 | Produces an SPDX JSON SBOM, attached as a cosign in-toto attestation. |
| OCI registry (kind) | `registry:3.1.2` (distribution v3) | Local stand-in for ECR on the `kind` Docker network. |
| local-kms (kind) | `nsmithuk/local-kms:3.11.7` | KMS API emulator, so Vault's `awskms` auto-unseal runs on kind with the same seal stanza as on AWS. Dev-only; it holds no real secrets. |
| Everything from Phase 1 | unchanged | |

Images are pinned by tag and digest.

## Design

### 1. Cardholder-data zone (CDE)

| | kind | AWS |
|---|---|---|
| Namespace | `fincore-cde` (payments-api, ledger, db-init), PSA `restricted`, label `fincore.io/zone=cde` | same |
| Nodes | Two extra workers (zones a, b), label `fincore.io/node-role=cde`, taint `fincore.io/zone=cde:NoSchedule` | Karpenter NodePool `cde`: on-demand, same taint and label, its own EC2NodeClass and security group |
| Outside the zone | `fincore` (notifier, webhook-sink, traffic generator), `fincore-data` (PostgreSQL and ElasticMQ, standing in for Aurora and SQS) | Aurora's security group admits only the CDE and Vault node security groups |

- **Isolation in both directions.** CDE pods must select CDE nodes. Pods outside `fincore-cde` may not tolerate the CDE taint. A Kyverno policy enforces both, so nothing else can be scheduled into the zone.
- **NetworkPolicies.** Default deny on ingress and egress in `fincore-cde`. Explicit allows:
  - DNS for every pod;
  - payments-api ingress from the traffic generator and the ALB;
  - ledger ingress from payments-api only;
  - egress from payments-api to the ledger, PostgreSQL and the queue;
  - egress from the ledger to PostgreSQL and Vault;
  - Prometheus scrapes on the metrics port.

  Supporting policies:
  - `fincore-data` admits PostgreSQL only from the CDE and Vault, and the queue only from the payments-api and notifier namespaces.
  - `fincore` gets default-deny ingress.
  - `vault` admits 8200 only from the CDE and itself.

  kind's kindnet enforces NetworkPolicy; this was verified on 2026-10-26. On AWS, the VPC CNI network-policy agent is switched on (`enableNetworkPolicy`).
- The zone boundary diagram goes in `docs/architecture.md`.

### 2. Vault: dynamic, short-lived database credentials

- **Deployment.** HA Raft with 3 replicas and `retry_join`, TLS on 8200 and 8201 via a cert-manager internal CA, and the agent injector.
- **Auto-unseal.** `seal "awskms"` with a dedicated KMS key, reached through EKS Pod Identity. On kind, the same stanza points at `local-kms` through `endpoint`.
- **Initialisation.** A one-time operator step, as on a real platform. `scripts/vault-init.sh` runs `vault operator init`, which yields recovery keys because of auto-unseal. The output is kept in the gitignored `.kube/vault-init.json`. The script then grants a scoped `vault-configurer` Kubernetes-auth role and **revokes the root token**.
- **Configuration is GitOps.** The `vault-config` app runs an idempotent Job on every sync. It authenticates with Kubernetes auth (no static token) and sets up:
  - a file audit device to stdout;
  - Kubernetes auth;
  - the `database/` engine with a PostgreSQL connection. The connection uses `vault_admin` (CREATEROLE, created by db-init), and Vault immediately runs `rotate-root`, so no human or Kubernetes Secret knows that password afterwards;
  - role `ledger`;
  - policy `ledger`, which may read `database/creds/ledger` and nothing else.
- **Dynamic users.** Each user is created `IN ROLE ledger` with `SET role = ledger`, so objects created by migrations are owned by the stable `ledger` role, and revocation can `DROP ROLE` cleanly. Revocation also terminates any straggling sessions.
- **Ledger.** The Vault Agent sidecar renders `/vault/secrets/db.json` (username and password). The Go pool gets a new `DB_CREDENTIALS_FILE` option, which re-reads the file for every new physical connection, logs and counts credential changes, and bounds connection lifetime (`DB_MAX_CONN_LIFETIME`). Rotated credentials are therefore picked up without a restart.
- **TTLs.**
  - kind: 3 minutes, so the demo shows a rotation within minutes.
  - AWS: 1 hour.
- **Static secrets** (webhook signing key, payments-api DB password) stay on External Secrets ← Secrets Manager, as in Phase 1. The plan asks for both patterns.

### 3. Supply chain: signed images with SBOMs

- **kind.** `scripts/build-images.sh` builds the images and pushes them to the local registry. `scripts/sign-images.sh` then runs Syft to produce the SBOM, `cosign sign`, and `cosign attest --type spdxjson`. Both tools run in pinned containers on the `kind` network, so the signed reference is the same one Kyverno verifies. The cosign key pair is generated once into `.kube/cosign/` (gitignored); the public key is published to the cluster as a ConfigMap.
- **CI.**
  - PRs generate and upload an SBOM per image.
  - `release.yml` pushes to ECR, then runs keyless `cosign sign` and `cosign attest` with GitHub OIDC (`id-token: write`), and records in Rekor.
- **Kyverno `ImageValidatingPolicy`** for `<our registry>/fincore/*`:
  - signature required (key on kind; on AWS, keyless identity `…/fincore/.github/workflows/release.yml@refs/heads/main` issued by `token.actions.githubusercontent.com`);
  - SPDX SBOM attestation required;
  - `mutateDigest` and `verifyDigest`, so a tag can never be swapped after verification.

### 4. Kyverno admission policies

These are in the top-level `policies/` Helm chart. They are enforced (`Deny`, `failurePolicy: Fail`) in namespaces labelled `fincore.io/policy=enforced` (`fincore`, `fincore-cde`), and cover Pods plus autogenerated Deployments, StatefulSets, Jobs and CronJobs:

| Policy | Rule |
|---|---|
| `require-non-root` | `runAsNonRoot: true`, no UID 0, on every container including init and ephemeral containers |
| `require-read-only-root-fs` | `readOnlyRootFilesystem: true` |
| `require-resources` | CPU and memory requests, a memory limit |
| `restrict-image-registries` | only `<our registry>/fincore/*`, plus an explicit allowlist of digest-pinned third-party images (Vault agent, PostgreSQL client for db-init) |
| `cde-node-isolation` | the CDE scheduling rules above |
| `verify-fincore-images` | signature and SBOM attestation, as in section 3 |

The CPU limit is deliberately not required: CPU throttling hurts p95 latency, while a missing memory limit is what hurts neighbours. `policies/tests/` runs `kyverno test` against passing and failing fixtures in `make check` and CI.

### 5. Edge and audit (AWS, Terraform)

- **New `waf` module.**
  - Regional web ACL with AWS managed rule groups: Common, KnownBadInputs, SQLi, Amazon IP reputation.
  - A rate-based rule per client IP.
  - Logging to a KMS-encrypted CloudWatch log group with the `authorization` header redacted.
  - Attached to the API's ALB through the ingress annotation (`alb.ingress.kubernetes.io/wafv2-acl-arn`), injected as a cluster value.
- **New `audit` module.** A multi-region CloudTrail trail with log-file validation and KMS, an S3 bucket (versioned, public access blocked, TLS only, 365-day retention) and CloudWatch Logs delivery.
- **EKS control-plane logs.** Already on from Phase 1 (`api`, `audit`, `authenticator`, `controllerManager`, `scheduler`).
- **Vault.**
  - a dedicated KMS unseal key;
  - a Pod Identity role allowing `kms:Encrypt`, `kms:Decrypt` and `kms:DescribeKey` on that key only;
  - the EBS CSI add-on with an encrypted gp3 StorageClass for Raft.
- **Network.**
  - CDE node security group and system-node security group;
  - Aurora admits only those two;
  - VPC CNI `enableNetworkPolicy`.

### 6. Documentation

- `docs/compliance-mapping.md`: each control mapped to the PCI DSS v4.0.1 requirement it illustrates, clearly labelled *illustrative, not a certified assessment*.
- `docs/architecture.md`: Mermaid diagram of the zone boundary and the credential flow.
- `docs/phase-2-results.md`: results with links to the evidence.
- README: a Phase 2 section.

## What runs where (new in Phase 2)

| Concern | AWS | kind |
|---|---|---|
| Image registry | ECR | `registry:3` container `fincore-registry` on the `kind` network (`localhost:5001` from the host) |
| Signing | keyless cosign (GitHub OIDC, Fulcio, Rekor) | cosign key pair generated locally, no transparency log |
| Vault unseal | AWS KMS | local-kms (same `awskms` seal, `endpoint` override) |
| Vault storage | Raft on encrypted gp3 EBS (EBS CSI) | Raft on kind's local-path volumes |
| CDE nodes | Karpenter NodePool `cde` with its own security group | two tainted kind workers |
| NetworkPolicy enforcement | VPC CNI network-policy agent | kindnet |
| WAF, CloudTrail | yes | n/a (documented, statically checked) |

## Work breakdown

1. **kind topology.**
   - Local registry; CDE workers; containerd `hosts.toml`.
   - Images pushed to the registry instead of `kind load`.
   - payments-api, ledger and db-init move to `fincore-cde`.
   - e2e and the release demos keep passing.
2. **NetworkPolicies**, plus `scripts/demo-netpol.sh`.
3. **Supply chain and Kyverno.**
   - Signing and SBOM scripts.
   - The Kyverno add-on and the `policies` chart, with `kyverno test` fixtures.
   - `scripts/demo-policies.sh`.
4. **Vault.**
   - local-kms, the internal CA, Vault HA.
   - `vault-init.sh` and the `vault-config` job.
   - db-init roles.
   - Go `DB_CREDENTIALS_FILE` with tests.
   - Ledger injection; `scripts/demo-rotation.sh`.
5. **AWS and CI.**
   - Terraform: waf, audit, KMS, EBS CSI, CDE NodePool and security groups, VPC CNI policy.
   - Release signing and attestation; PR SBOMs.
   - CRD JSON schemas generated from the pinned charts for kubeconform; `kyverno test` in `check.sh`.
6. **Proof.**
   - Fresh cluster, B1 to B4, evidence, docs.
   - PR `phase-2` → `main`.

## Risks and fallbacks

| Risk | Fallback |
|---|---|
| Kyverno 1.19 may not verify cosign v3's default (new bundle) signatures, or the reverse. | Test it first. If the formats disagree, sign in the format Kyverno verifies (cosign flags) and record the reason. |
| local-kms may not cover the KMS calls Vault's seal makes. | Transit auto-unseal from a tiny dev Vault; record as a deviation. |
| Memory on the 8 GB Docker VM. Two more nodes, Vault ×3 and Kyverno add about 1 GB; the current pods use about 4 GB. | Reduce Prometheus retention and Kyverno controllers (the reports controller is optional). |
| Default-deny could break kubelet probes or Prometheus scrapes on kindnet. | Explicit allows. Verified in step 2 before policies are layered on. |
| Credential rotation could race with in-flight connections. | Connection lifetime (15 s) is far below the remaining lease at re-render. Revocation terminates sessions only after the agent has switched. The demo asserts zero errors. |

## Out of scope for Phase 2

- Loki and Tempo shipping of audit logs (Phase 3; Vault audit goes to stdout, ready for collection).
- Chaos and DR (Phase 3).
- A real PCI assessment. The mapping is illustrative.
