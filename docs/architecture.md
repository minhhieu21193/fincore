# Architecture

This document grows with each phase. Phase 2 adds the cardholder-data zone,
the credential flow and the admission path. The network, GitOps and
observability views arrive with Phase 3 and the final docs.

## Cardholder-data zone (CDE) boundary

Everything that processes payments or holds money movements lives in namespace
`fincore-cde`, on dedicated tainted nodes, behind default-deny NetworkPolicies
for both directions. Each arrow below is an explicit allow rule; everything else
is dropped. [`scripts/demo-netpol.sh`](../scripts/demo-netpol.sh) proves it.

```mermaid
flowchart LR
  subgraph internet[Internet]
    client([Merchant / client])
  end

  subgraph edge[Edge - AWS]
    waf[AWS WAF<br/>managed rules + rate limit]
    alb[ALB<br/>TLS 1.3]
  end

  subgraph app["namespace fincore (outside the zone)"]
    tg[traffic-generator]
    notifier[notifier]
    sink[webhook-sink<br/>demo merchant]
  end

  subgraph cde["namespace fincore-cde: cardholder-data zone<br/>dedicated tainted nodes, default deny in and out"]
    api[payments-api]
    ledger[ledger<br/>+ Vault Agent]
    dbinit[db-init job]
  end

  subgraph data["data stores (AWS: Aurora + SQS, kind: fincore-data)"]
    pg[(PostgreSQL<br/>payments, ledger)]
    q[[queue<br/>payment events + DLQ]]
  end

  subgraph vaultns[namespace vault]
    vault[Vault HA<br/>3 x Raft, TLS]
  end

  kms[(KMS<br/>auto-unseal key)]

  client --> waf --> alb -->|8080| api
  tg -->|8080| api
  api -->|8080| ledger
  api -->|5432| pg
  api -->|outbox relay| q
  ledger -->|5432, Vault-issued user| pg
  ledger -->|8200 TLS| vault
  dbinit -->|5432| pg
  vault -->|5432, CREATEROLE only| pg
  vault -.->|Encrypt / Decrypt| kms
  q --> notifier -->|signed webhook| sink

  classDef zone fill:#fde8e8,stroke:#c0392b,stroke-width:2px;
  class api,ledger,dbinit zone;
  style cde fill:#fff5f5,stroke:#c0392b,stroke-width:4px,stroke-dasharray:8 4
  style app fill:#f5f8ff,stroke:#5b7bb2
  style data fill:#f7f7f7,stroke:#888
  style vaultns fill:#f6f2ff,stroke:#7d5ba6
  style edge fill:#f2fbf5,stroke:#3b8a5a
```

| From → to | Why it is allowed | Rule |
|---|---|---|
| ALB (public subnets) / traffic generator → payments-api:8080 | the public API | `payments-api-ingress` |
| payments-api → ledger:8080 | posting double-entry transactions | `ledger-ingress`, `payments-api-egress` |
| payments-api → PostgreSQL:5432, queue (kind 9324 / AWS SQS endpoint 443) | payments and the transactional outbox | `payments-api-egress` |
| payments-api → Pod Identity agent (AWS) | SDK credentials for SQS | `payments-api-egress` |
| ledger → PostgreSQL:5432, Vault:8200 | its database, its credentials | `ledger-egress` |
| any zone pod → kube-dns:53 | name resolution | `allow-dns` |
| Prometheus → :9090 | metrics (canary analysis) | `allow-metrics-scrape` |
| *anything else, including the internet* | **denied** | `default-deny` |

On AWS the same boundary also holds one layer down. Aurora's security group
admits only the CDE node security group and the system node security group
(Vault). Karpenter's ordinary workload nodes don't carry either group.

## Database credentials: no static password for the ledger

```mermaid
sequenceDiagram
  autonumber
  participant L as ledger pod
  participant A as Vault Agent (sidecar)
  participant V as Vault
  participant P as PostgreSQL

  Note over A: token with audience "vault"<br/>(projected; the Kubernetes API rejects it)
  A->>V: login (Kubernetes auth, role ledger)
  V-->>A: Vault token (policy ledger-db: read database/creds/ledger)
  A->>V: read database/creds/ledger
  V->>P: CREATE ROLE "v-…" LOGIN VALID UNTIL +TTL IN ROLE ledger; SET role = ledger
  V-->>A: username + password, lease TTL (3 min on kind, 1 h on AWS)
  A->>L: render /vault/secrets/db.json
  L->>P: new connections read the file (DB_CREDENTIALS_FILE)
  Note over A,V: before the lease ends: new user, file re-rendered
  L->>P: recycled connections (DB_MAX_CONN_LIFETIME) use the new user
  V->>P: lease expired: terminate leftover sessions, DROP ROLE "v-…"
```

- Dynamic users act as the stable `ledger` role (`SET role`). Tables created
  by migrations are therefore owned by `ledger`, and dropping an expired user
  never strands objects.
- Vault connects as `vault_admin`, which has `CREATEROLE` plus admin on `ledger`
  and nothing else. Its bootstrap password is rotated by Vault on first use.
- Every issuance is in Vault's audit log with the requesting service account.

## Admission path: what may run in FinCore namespaces

```mermaid
flowchart LR
  ci[CI release.yml<br/>build, Trivy, push to ECR] --> sign[cosign sign + attest SBOM<br/>keyless, GitHub OIDC, Rekor]
  sign --> git[bump tag in gitops/] --> argo[Argo CD sync]
  argo --> api[Kubernetes API]
  api --> mut[Kyverno: resolve tag to digest]
  mut --> inj[Vault injector: add agent<br/>CDE only, fails closed]
  inj --> val{Kyverno policies}
  val -->|signature + SBOM verified,<br/>registry, non-root, read-only FS,<br/>limits, CDE placement| psa[Pod Security restricted] --> run([pod runs])
  val -->|any violation| deny([rejected with the reason])
```
