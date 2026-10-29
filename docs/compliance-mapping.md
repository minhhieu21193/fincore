# Compliance mapping (PCI DSS v4.0.1)

> **Illustrative, not a certified assessment.** This table shows which PCI DSS
> v4.0.1 requirement each FinCore control is meant to illustrate, and where to
> find the code and the evidence. It has not been reviewed by a QSA. FinCore is a
> demo: the card numbers it handles are test tokens (`tok_visa`), and no primary
> account number (PAN) is ever stored.

Legend for the evidence column:
- **kind**: proven on the local cluster, with a log in [`docs/evidence/phase-2/`](evidence/phase-2/);
- **static**: enforced by a check in CI (`make check`);
- **AWS**: written in Terraform and statically checked, but not yet applied (the owner's demo day).

## Network segmentation: the cardholder-data zone

| Control | Where | Evidence | PCI DSS v4.0.1 |
|---|---|---|---|
| Cardholder-data zone (CDE) as its own namespace, `fincore-cde` (payments-api, ledger, db-init) | `gitops/bootstrap/app-of-apps/values.yaml` (`cde-base`) | kind | 12.5.2 scope is documented; 1.2.3 network diagram ([architecture](architecture.md)) |
| Dedicated, tainted CDE nodes. Pods outside the zone cannot tolerate the taint, and zone pods cannot leave it (Kyverno). | kind: a dedicated tainted worker. AWS: Karpenter NodePool `cde` (`gitops/platform/karpenter-nodepools/templates/cde.yaml`). `policies/templates/cde-node-isolation.yaml` | kind (`policies.log` cases 9 and 10), static (`kyverno test`) | 2.2.3 primary functions with different security levels are isolated |
| Default-deny NetworkPolicies for ingress **and** egress in the CDE; every allowed flow is listed and explained in code | `gitops/apps/fincore-base/templates/networkpolicies.yaml` | kind (`netpol.log`) | 1.2.1 network security control rule sets defined and maintained; 1.3.1 inbound CDE traffic restricted; 1.3.2 outbound CDE traffic restricted |
| No internet egress from the CDE | the same file | kind (`netpol.log`, "internet BLOCKED") | 1.3.2, 1.4.2 |
| Database reachable only from the zone and Vault. On AWS, Aurora admits exactly two security groups: CDE nodes and system nodes. | `gitops/platform/local-infra/networkpolicies.yaml`, `terraform/envs/demo/main.tf` (module `aurora`) | kind (`netpol.log`), AWS | 1.3.1, 1.4.4 system components storing cardholder data are not directly reachable from untrusted networks |
| NetworkPolicy enforcement on EKS (VPC CNI network-policy agent) | `terraform/modules/eks/main.tf` (`enableNetworkPolicy`) | AWS | 1.2.1 |
| Data-flow diagram of the zone boundary | [`docs/architecture.md`](architecture.md) | doc | 1.2.4 accurate data-flow diagrams |

## Secure configuration and supply chain

| Control | Where | Evidence | PCI DSS v4.0.1 |
|---|---|---|---|
| No root containers, read-only root filesystem, all capabilities dropped. Enforced at admission (Kyverno, which also catches Deployments) and by Pod Security `restricted`. | `policies/templates/require-*.yaml`, namespace labels | kind (`policies.log` cases 5–7), static | 2.2.1 configuration standards; 2.2.6 security parameters configured to prevent misuse |
| Resource requests and memory limits required | `policies/templates/require-resources.yaml` | kind (case 8), static | 2.2.1 |
| Images only from our registry (ECR), plus an allowlist of digest-pinned third-party images | `policies/templates/restrict-image-registries.yaml` | kind (case 4), static | 6.3.2 inventory of bespoke and third-party software components; 2.2.1 |
| Every image signed by the release pipeline (cosign keyless, GitHub OIDC identity of `release.yml@main`, recorded in Rekor). Kyverno verifies the signature at admission and pins the tag to the verified digest. | `.github/workflows/release.yml`, `policies/templates/verify-images.yaml` | kind (cases 1, 3, 11; locally with a key), AWS (keyless) | 6.3.2; 6.5.1 changes follow a controlled process; 6.4.3 (by analogy: only authorised code runs) |
| Signed SBOM (SPDX, Syft) attached to every image; images without one are rejected | `scripts/publish-image.sh`, `release.yml`, `ci.yml` (SBOM artifact on every PR) | kind (case 2), CI | 6.3.2 inventory of software components |
| Vulnerability gate: fixable HIGH/CRITICAL findings fail the build (Trivy) | `.github/workflows/ci.yml`, `release.yml` | CI | 6.3.3 known vulnerabilities patched; 11.3.1 internal vulnerability scans (illustrative) |
| All changes go through git (Argo CD self-heal reverts drift). Infrastructure is code with policy checks (checkov, tflint). | `gitops/`, `terraform/`, `scripts/check.sh` | CI, kind | 6.5.1 change management; 1.2.2 changes to network connections approved and managed |

## Secrets, credentials and keys

| Control | Where | Evidence | PCI DSS v4.0.1 |
|---|---|---|---|
| The ledger has **no static database password**. Vault issues a PostgreSQL user per pod, valid for 3 minutes on kind and 1 hour on AWS, and drops it when the lease ends. | `gitops/platform/vault-config/`, `gitops/apps/ledger/values.yaml` | kind (`rotation.log`) | 8.6.2 no hard-coded passwords for application accounts; 8.6.3 application passwords changed periodically; 8.3.9 |
| Rotation without a restart: the service re-reads the credentials file per connection | `internal/platform/pg/pg.go` (+ `TestConnectPicksUpRotatedCredentials`) | kind (`rotation.log`), CI test | 8.6.3 |
| Vault's own database admin password is rotated by Vault on first use (`rotate-root`): afterwards no human and no Kubernetes Secret knows it | `gitops/platform/vault-config/files/configure.sh` | kind | 8.6.3; 7.2.5 least privilege for system accounts |
| Least privilege: the ledger's Vault policy reads only `database/creds/ledger`; its users are members of the `ledger` role only. Each AWS client has its own Pod Identity role. | `vault-config` (`policy.<name>-db.hcl`), `terraform/modules/eks/main.tf` | kind, AWS | 7.2.1, 7.2.2 access by need to know; 7.2.5 |
| The Vault root token is revoked right after initialisation; configuration uses Kubernetes auth with a token whose audience is `vault` (the Kubernetes API rejects it) | `scripts/vault-init.sh`, `vault-config` Job | kind (kind-up log) | 8.2.2 shared and generic accounts are not used routinely; 7.2.5 |
| Vault auto-unseal with a dedicated KMS key (Encrypt, Decrypt and DescribeKey only); recovery keys held offline | `terraform/envs/demo/main.tf` (`vault_kms`), `terraform/modules/eks/main.tf` | kind (local KMS emulator), AWS | 3.6.1 key-management procedures; 3.7.x (illustrative) |
| Encryption in transit inside the cluster: Vault API and Raft traffic over TLS 1.3 (internal CA via cert-manager); the public ALB uses `ELBSecurityPolicy-TLS13-1-2-2021-06` | `gitops/platform/vault/values.yaml`, `gitops/envs/aws/values/payments-api.yaml` | kind, AWS | 4.2.1 strong cryptography over open, public networks |
| Encryption at rest with customer-managed KMS keys, **one per data domain** (table below), each rotated every 90 days | `terraform/envs/demo/main.tf`, `terraform/modules/kms/` | AWS, static (`terraform test`) | 3.5.1 (illustrative; FinCore stores no PAN); 3.6.1 key-management procedures; 3.7.4 keys changed at the end of their cryptoperiod |
| The CDE key can't be used directly. Its key policy denies Encrypt, Decrypt and GenerateDataKey to every IAM principal unless the call comes through SQS, RDS, Secrets Manager or EC2 (node volumes) (`kms:ViaService`). An IAM policy with `kms:*` still cannot decrypt cardholder-data-zone data outside those services. | `terraform/modules/kms/main.tf` (`OnlyThroughServices`); the backups key likewise through S3 only | static (`terraform/modules/kms/tests`), AWS | 3.6.1.3 access to keys restricted to the fewest custodians necessary; 7.2.2 |
| payments-api and the notifier may use only the CDE key, only through SQS, and only for the payment-events queue (`kms:EncryptionContext:aws:sqs:arn`). payments-api may GenerateDataKey and Decrypt; the notifier may only Decrypt. | `terraform/modules/eks/main.tf` (`payments_api`, `notifier`) | static (`terraform/modules/eks/tests`), AWS | 7.2.1, 7.2.2 access by need to know; 7.2.5 least privilege for application accounts |
| External Secrets opens each key only through Secrets Manager and only for that key's secrets (`kms:EncryptionContext:SecretARN`): the CDE key for the CDE secrets, the platform key for the platform ones. The module's default policy (an unconditioned `kms:Decrypt`, which falls back to every key) is not used. The backup writers (Velero, Vault snapshot) use only the backups key, only for the backup bucket (`kms:EncryptionContext:aws:s3:arn`). | `terraform/modules/eks/main.tf` (`external_secrets`, `backups`) | static (`terraform/modules/eks/tests`), AWS | 7.2.2, 7.2.5 |
| Node disks on customer keys: CDE nodes' root volumes on the CDE key (they hold the zone's container logs and `emptyDir` data), general nodes' on the platform key. The Karpenter controller may use the two keys only through EC2, and may create grants only for AWS resources. | `gitops/platform/karpenter-nodepools/` (`kmsKeyID`), `terraform/modules/eks/main.tf` (`karpenter_ebs_kms_statements`) | static (`make check` render, `terraform test`), AWS | 3.5.1 (illustrative), 7.2.5 |
| Backups hold no CDE credential: Velero backs up `fincore-cde` on its own schedule **without Secrets**. After a restore External Secrets recreates them from Secrets Manager, and the ledger's Vault-issued credentials are never Secrets. | `gitops/envs/aws/values/velero.yaml`, [DR runbook](runbooks/disaster-recovery.md) | static (`make check` asserts no schedule includes CDE Secrets), AWS | 8.3.2 authentication factors protected in storage (here: kept out of backups entirely); 7.2.2 |

KMS keys by data domain (all symmetric, customer-managed, rotated every 90 days):

| Key | Encrypts | Who may use it |
|---|---|---|
| `fincore-demo-cde` | Payment-events queue and its dead-letter queue (SQS); Aurora storage, its log group and Performance Insights; the secrets that open the database (`fincore-payments-db`, `fincore-vault-db-admin` or `fincore-ledger-db`, the Aurora master secret); root volumes of the CDE nodes | Only through SQS, RDS, Secrets Manager and EC2. payments-api and the notifier, for the queue only; External Secrets, for those secrets only; CloudWatch Logs, for Aurora's log group only; the Karpenter controller, through EC2, to launch CDE nodes. 30-day deletion window. |
| `fincore-demo-platform` | Kubernetes Secrets (EKS envelope encryption), EBS (root volumes of system and general Karpenter nodes, PersistentVolumes of Vault, Prometheus, Loki, Tempo), ECR images, VPC flow logs, EKS control-plane and WAF logs, `fincore-webhook-signing` | EKS, the EBS CSI driver, EC2 Auto Scaling and EC2 Spot service-linked roles (node volumes; grants for AWS resources only), the Karpenter controller (through EC2), CloudWatch Logs, External Secrets (for `fincore-webhook-signing` only) |
| `fincore-demo-backups` | The backup bucket (Velero cluster state, Vault Raft snapshots) | Only through S3, and only for the backup bucket: Velero and the Vault snapshot job. 30-day deletion window. |
| `fincore-demo-vault-unseal` | Vault's root key (auto-unseal) | Vault's Pod Identity role: Encrypt, Decrypt and DescribeKey. Absent in the small-team profile. |
| `fincore-demo-audit` | CloudTrail logs | CloudTrail and CloudWatch Logs, for the trail only (`terraform/modules/audit`) |

Aurora's logs and Performance Insights use the CDE key, not the platform key: slow-query logs and Performance Insights keep SQL text, which belongs to the cardholder-data zone.
| Static secrets from AWS Secrets Manager via External Secrets; nothing secret is committed. Locally generated material stays in the gitignored `.kube/`. | `gitops/apps/fincore-base/templates/externalsecrets.yaml` | kind, static | 8.3.2, 3.6.1 |

## Edge protection

| Control | Where | Evidence | PCI DSS v4.0.1 |
|---|---|---|---|
| AWS WAF on the API's ALB: AWS managed rule groups (IP reputation, common exploits, known-bad inputs including Log4Shell, SQL injection) and a per-IP rate limit; logs to CloudWatch with credentials redacted | `terraform/modules/waf/`, ingress annotation in `gitops/envs/aws/app-of-apps.yaml` | AWS, static (checkov) | 6.4.2 automated technical solution against web-based attacks for public-facing web applications; 1.4.1 |

## Audit logging

| Control | Where | Evidence | PCI DSS v4.0.1 |
|---|---|---|---|
| CloudTrail: multi-region, log-file validation, its own KMS key, S3 bucket (versioned, private, TLS-only) and CloudWatch Logs; 365-day retention | `terraform/modules/audit/` | AWS, static | 10.2.1 audit logs enabled; 10.3.2 logs protected from modification; 10.3.4 change detection on logs (digest files); 10.5.1 at least 12 months of history |
| EKS control-plane logs (`api`, `audit`, `authenticator`, `controllerManager`, `scheduler`), KMS-encrypted | `terraform/modules/eks/main.tf` | AWS | 10.2.1, 10.2.2 |
| Vault audit device: every request and response, with secrets HMAC'd, to stdout and collected with pod logs. Credential issuance to the ledger is traceable to its service account. | `vault-config` (`vault audit enable file`) | kind (`rotation.log`, audit excerpt) | 10.2.1.2 actions by administrative and application accounts; 10.2.2 |

## Small-team profile

`terraform/envs/demo/profiles/small-team.tfvars` (Terraform `secrets_backend = "secrets-manager"`, GitOps overlay `gitops/envs/aws/secrets-manager/`) removes Vault for a team that cannot operate it. Costs: [`cost.md`](cost.md#small-team-profile). Rendered and checked by `make check` (no Vault apps, the ledger reads its password from Secret `ledger-db`).

| Changes | Effect on the controls above |
|---|---|
| The ledger logs in as its owner role with a **static password** from Secrets Manager (CDE key), synced by External Secrets, like payments-api | Loses "no static database password" (8.6.2 is then met by Secrets Manager rather than by having no password) and the 3-minute / 1-hour credential lifetime. 8.6.3 (periodic change) becomes a procedure: change the secret in Secrets Manager; db-init applies it on the next sync and pods pick it up on restart. No automatic rotation is configured; Secrets Manager rotation would need a rotation Lambda per secret. |
| No Vault audit device | Credential reads are still logged, by CloudTrail (`GetSecretValue` by the External Secrets role, 10.2.1), but per-pod issuance is no longer traceable to a service account |
| No Vault unseal key, no Vault and Vault-snapshot Pod Identity roles | Fewer keys and roles to manage |
| Aurora admits only the CDE nodes' security group (the system nodes only needed it for Vault) | Narrower database access (1.3.1, 1.4.4) |
| 2 system nodes and 1 NAT gateway | Availability, not compliance: losing the NAT's AZ cuts internet egress (webhooks to merchants) until it returns; AWS APIs keep working through the VPC endpoints |

The KMS split, the CDE key's service-only use and the per-workload encryption-context conditions are the same in both profiles.

## Not covered (gaps a real assessment would raise)

- **No QSA review.** The requirement numbers above are our reading of PCI DSS v4.0.1.
- **People and process requirements (12.x).** Policies, training, incident response and vendor management are out of scope. Runbooks arrive in Phase 3.
- **Multi-factor authentication for administrative access (8.4).** Access to AWS and the cluster is the owner's account; SSO with MFA is not modelled.
- **Continuous compliance scanning.** Kyverno enforces at admission only. Its background scans and PolicyReports are switched off: on the small demo cluster they cost more API-server memory than the application. Production would enable them on a larger control plane.
- **Host integrity and intrusion detection (11.5).** No file-integrity monitoring on nodes and no runtime threat detection (e.g. GuardDuty EKS Runtime Monitoring or Falco).
- **Audit logs are not centralised in-cluster yet.** Shipping Vault and application logs to Loki (and CloudWatch) is Phase 3. Cross-region replication of the CloudTrail bucket is left as a production step.
- **NetworkPolicy start-up window.** A newly started pod is unrestricted for about a second, until the policy engine programs its rules. This was measured on kind (kindnet), and the VPC CNI's default "standard" mode behaves the same. The VPC CNI's strict mode closes the window, but it denies every pod without a policy cluster-wide, so it needs policies for all platform namespaces first.
- **Penetration testing and segmentation testing (11.4).** The NetworkPolicy demo is a functional test, not a penetration test.
- **Untested on AWS:** the KMS conditions above are checked statically. Their behaviour against real services (SQS's dead-letter move, Performance Insights, EBS at launch) is the first part of [`aws-demo-day.md`](aws-demo-day.md).
- **The demo is single-region and single-account.** Production would separate the CDE into its own AWS account, so the CDE key and its data would sit behind an account boundary as well as a key policy.
