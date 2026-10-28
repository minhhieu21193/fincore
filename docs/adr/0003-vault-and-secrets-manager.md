# 0003. Vault for dynamic credentials, Secrets Manager for static secrets

**Status:** accepted (Phase 2)

## Context

PCI DSS asks for unique, short-lived, rotated credentials and for an audit trail of who used them (requirements 3, 7, 8 and 10; see `docs/compliance-mapping.md`). The ledger is the most sensitive service: it holds money movements.

## Decision

- **Secrets Manager** (through External Secrets) holds the static secrets: the payments database password and the webhook signing key. Rotation is a Secrets Manager rotation followed by an ESO refresh.
- **Vault** (HA Raft, TLS, AWS KMS auto-unseal, audit device on) issues the **ledger's database users dynamically**: each pod gets its own PostgreSQL user, valid for 1 hour (3 minutes on kind), created `IN ROLE ledger` and revoked on expiry. Vault's own database admin password is rotated by Vault (`rotate-root`) on first use, so nobody knows it. Vault is configured only from git (a Job using Kubernetes auth); the root token is revoked after initialisation.

## Alternatives

- **Secrets Manager only, with rotation Lambdas.** It is simpler and fully managed. But rotation changes a shared password on a schedule: every pod uses the same user, rotations race with connection pools, and the database log cannot tell which pod did what. Short-lived per-pod users are not something Secrets Manager provides.
- **IAM database authentication.** Per-pod tokens with no secret at all, but they're limited by connection-rate quotas and tied to AWS. The kind environment could not reproduce it.

## Consequences

- Each credential is unique per pod and short-lived. The rotation demo shows no restart and no error (`docs/evidence/phase-2/rotation.log`).
- Vault is a stateful, critical service: three nodes, quorum, snapshots every 15 minutes, a tested restore (`docs/evidence/phase-3/dr-drill.md`), and a runbook (`docs/runbooks/vault-sealed.md`).
- The ledger cannot start without Vault: the injector fails closed. That's deliberate, because a ledger pod without its credentials agent must not run.
