# 0005. Aurora Serverless v2, not provisioned instances

**Status:** accepted (Phase 1)

## Context

FinCore needs PostgreSQL with multi-AZ failover, point-in-time recovery and encryption. The demo environment sits idle most of the time; production load follows business hours.

## Decision

Aurora PostgreSQL 17, Serverless v2, a writer and a reader in different AZs, scaling between 0.5 and 8 ACU (1 ACU ≈ 2 GiB of memory). Storage is encrypted with the platform KMS key, backups are kept 7 days with point-in-time recovery, the master password is managed by RDS in Secrets Manager, and applications use their own roles.

## Alternatives

- **Provisioned Aurora (e.g. db.r7g.large × 2).** The price is predictable, and cheaper per hour under constant high load. But it pays for peak capacity around the clock, and resizing means a failover.
- **RDS PostgreSQL Multi-AZ.** It's cheaper at small sizes, with a synchronous standby. But failover takes longer (AWS documents 60–120 s for Multi-AZ instances, versus typically under a minute for Aurora with a replica), and the standby can't serve reads.
- **Self-managed on Kubernetes.** See the ADR index.

## Consequences

- At idle, cost follows the 0.5 ACU floor per instance. Under load it scales in seconds (`docs/cost.md` computes both).
- The services' connection budget (pods × pool, at most 100 at maximum replicas) is written next to the pool setting; it must stay below the cluster's `max_connections`, checked whenever replica counts or ACU limits change.
- Failover can be tested: `scripts/chaos-aws.sh db-failover`. On kind a PostgreSQL restart stands in.

**Revisit when** load is steady and high enough that provisioned instances (with reserved pricing) cost less than the ACU-hours actually used.
