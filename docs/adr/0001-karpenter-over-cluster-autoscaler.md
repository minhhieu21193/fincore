# 0001. Karpenter, not Cluster Autoscaler

**Status:** accepted (Phase 1)

## Context

FinCore's load varies: payments follow business hours, and canary releases briefly need extra pods. The cardholder-data zone (CDE) needs its own nodes, tainted, on-demand, with an extra security group that Aurora admits; everything else should run as cheaply as possible.

## Decision

Karpenter provisions all workload nodes. A small managed node group (2 × m7g.large) runs only the cluster add-ons Karpenter itself needs.

- NodePool `spot` (weight 100) and `on-demand` (weight 10): Graviton and x86, families c/m/r, generation > 5. Karpenter picks the cheapest instance that fits the pending pods and falls back to on-demand when Spot capacity is short.
- NodePool `cde`: on-demand only, tainted `fincore.io/zone=cde`, its own EC2NodeClass with the CDE security group; consolidated only when empty, one node at a time.
- Consolidation replaces under-used nodes; nodes expire after 30 days, so the AMIs stay current.

## Alternatives

- **Cluster Autoscaler with managed node groups.** It needs one node group per instance shape, capacity type and zone, so expressing "cheapest of many shapes, Spot first" means many groups and priority expanders. It scales node groups, not pods, so it reacts more slowly and bin-packs less well. Separating the CDE would mean yet another set of groups.
- **EKS Auto Mode.** It removes the add-on node group and Karpenter upkeep, but it charges a per-instance management fee, and the node classes are less flexible (the CDE security group, AMI pinning). It's a reasonable choice for a team that doesn't want to own Karpenter.

## Consequences

- The Spot share and instance choice are visible and tunable per NodePool, so cost follows load (`docs/cost.md`).
- Karpenter is one more controller to upgrade. It runs on the managed node group, so it never evicts itself.
- On kind there is no Karpenter. The zones and the CDE taint are reproduced with labelled kind nodes, so placement rules are tested even though node provisioning is not.

**Revisit when** the team would rather pay the Auto Mode fee than run Karpenter.
