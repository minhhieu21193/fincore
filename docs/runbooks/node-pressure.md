# Node pressure

**Symptoms:** pods `Evicted` or `Pending`, node conditions `MemoryPressure` / `DiskPressure` / `PIDPressure`, latency up everywhere at once (FinCore / Platform: node CPU and memory).

## Check

```
kubectl get nodes -L topology.kubernetes.io/zone,fincore.io/node-role
kubectl describe node <node> | sed -n '/Conditions/,/Addresses/p;/Allocated resources/,/Events/p'
kubectl get pods -A --field-selector=status.phase=Pending
kubectl top nodes; kubectl top pods -A --sort-by=memory | head -15
```

## Act

| Situation | Action |
|---|---|
| AWS, general nodes full | Karpenter adds nodes within ~1 minute; check `kubectl -n kube-system logs deploy/karpenter`; NodePool limits (`gitops/platform/karpenter-nodepools`) not reached |
| AWS, CDE nodes full | The `cde` NodePool is separate (tainted, 3 AZs); same checks on that pool. Nothing else may schedule there (admission policy). |
| A pod far above its request | It is the noisy neighbour: its memory limit will OOM-kill it before the node suffers. If it is a FinCore service, look at the RED dashboard and the latest release |
| `DiskPressure` | Logs or images. Container logs rotate (kubelet); images are garbage-collected at 85 %. On kind: `docker system df`, prune the build cache |
| kind | All nodes share one Docker VM (6 CPUs / 10 GB). Pressure there is the laptop's limit: see `docs/decisions-log.md` for the kind-only tuning |

## Draining a node for maintenance

`kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=5m` respects PodDisruptionBudgets: payments-api, the ledger, the notifier and Vault keep at most one pod down at a time. A drain that stops on "Cannot evict pod" is a budget doing its job: wait for the replacement to be ready, or add capacity first. On kind, pods with local volumes (PostgreSQL, Loki, Tempo, Vault) cannot move to another node; they wait for the node to come back (`docs/evidence/phase-3/chaos.md`).
