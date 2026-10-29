#!/usr/bin/env bash
# Destroy the AWS demo environment, in an order that leaves nothing billable.
# Never run in this project; kept as the reviewed, ordered procedure.
#
#   FINCORE_AWS=confirm scripts/down.sh      # FINCORE_PROFILE as for up.sh
#
# Terraform does not know about what controllers create at runtime, so
# those go first, while the controllers are still running to clean up:
#   1. Argo CD stops reconciling (root app deleted without cascading).
#   2. Ingresses deleted: the AWS Load Balancer Controller removes the ALB and
#      its security groups and target groups.
#   3. Karpenter NodePools deleted: Karpenter drains and terminates its nodes.
#   4. PVCs deleted: the EBS volumes go (Retain classes are not used).
#   5. terraform destroy (EKS, Aurora, VPC, ...); the state bucket is kept.
#   6. Leftover check: anything still tagged for the project, any load
#      balancer, instance, volume, address or NAT gateway in the region.
# The EC2 Auto Scaling and Spot service-linked roles that up.sh may have
# created stay: they are account-wide, free, and other workloads use them.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need aws terraform kubectl jq

[[ "${FINCORE_AWS:-}" == confirm ]] || die "this destroys an AWS environment; set FINCORE_AWS=confirm to proceed"
ENV_DIR="$ROOT/terraform/envs/demo"
export KUBECONFIG="$ROOT/.kube/aws-config"
NAME="$(terraform -chdir="$ENV_DIR" output -raw cluster_name)"
REGION="$(aws configure get region)"

if kubectl get nodes >/dev/null 2>&1; then
  log "1/6 Argo CD: stop reconciling"
  kubectl -n argocd patch application root --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
  kubectl -n argocd delete application root --wait=false >/dev/null 2>&1 || true
  for app in $(kubectl -n argocd get applications.argoproj.io -o name 2>/dev/null); do
    kubectl -n argocd patch "$app" --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null || true
  done

  log "2/6 load balancers (Ingresses and LoadBalancer Services)"
  kubectl delete ingress -A --all --wait=true --timeout=10m
  kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type == "LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' |
    while read -r ns svc; do kubectl -n "$ns" delete svc "$svc" --wait=true --timeout=10m; done
  wait_for "the ALBs to be gone" 900 bash -c \
    "[[ -z \$(aws elbv2 describe-load-balancers --query \"LoadBalancers[?contains(LoadBalancerName, 'k8s-')].LoadBalancerArn\" --output text) ]]"

  log "3/6 Karpenter nodes"
  kubectl delete nodepools.karpenter.sh --all --wait=true --timeout=15m
  wait_for "Karpenter nodes to terminate" 900 bash -c \
    "[[ -z \$(aws ec2 describe-instances --filters Name=tag:karpenter.sh/nodepool,Values=* Name=instance-state-name,Values=pending,running,stopping \
      --query 'Reservations[].Instances[].InstanceId' --output text) ]]"

  log "4/6 persistent volumes"
  kubectl delete pvc -A --all --wait=true --timeout=10m
fi

log "5/6 terraform destroy (about 20 minutes)"
tf_profile_args
terraform -chdir="$ENV_DIR" destroy -input=false -auto-approve ${TF_PROFILE_ARGS[@]+"${TF_PROFILE_ARGS[@]}"}

log "6/6 leftover check in $REGION"
left=0
report() { # description, newline-separated ids
  if [[ -n "$2" && "$2" != None ]]; then warn "LEFT: $1: $(echo "$2" | tr '\n\t' '  ')"; left=1; fi
}
report "resources tagged Project=fincore" "$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=fincore \
  --query 'ResourceTagMappingList[].ResourceARN' --output text)"
report "EKS clusters" "$(aws eks list-clusters --query "clusters[?@=='$NAME']" --output text)"
report "load balancers" "$(aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-')].LoadBalancerName" --output text)"
report "instances of the cluster" "$(aws ec2 describe-instances --filters "Name=tag:kubernetes.io/cluster/$NAME,Values=*" \
  Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)"
report "EBS volumes of the cluster" "$(aws ec2 describe-volumes --filters "Name=tag:kubernetes.io/cluster/$NAME,Values=*" --query 'Volumes[].VolumeId' --output text)"
report "NAT gateways" "$(aws ec2 describe-nat-gateways --filter "Name=tag:Project,Values=fincore" Name=state,Values=available,pending \
  --query 'NatGateways[].NatGatewayId' --output text)"
report "Elastic IPs" "$(aws ec2 describe-addresses --filters "Name=tag:Project,Values=fincore" --query 'Addresses[].AllocationId' --output text)"
report "Aurora clusters" "$(aws rds describe-db-clusters --query "DBClusters[?starts_with(DBClusterIdentifier, '$NAME')].DBClusterIdentifier" --output text)"
[[ $left == 0 ]] || die "billable resources are left (above); delete them or rerun this script"
ok "nothing billable left (the Terraform state bucket from terraform/bootstrap is kept on purpose)"
