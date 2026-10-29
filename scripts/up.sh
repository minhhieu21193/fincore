#!/usr/bin/env bash
# Create the AWS demo environment (spends money: about $34 a day idle, see docs/cost.md).
# Never run in this project; kept as the reviewed, ordered procedure.
#
#   FINCORE_AWS=confirm scripts/up.sh
#   FINCORE_AWS=confirm FINCORE_PROFILE=small-team scripts/up.sh   # profiles/small-team.tfvars
#
# Order: state bucket (terraform/bootstrap, once) -> the demo environment
# (VPC, EKS, Aurora, ...; Argo CD and the root app are installed by Terraform)
# -> kubeconfig -> wait until every Argo CD application is Synced and Healthy
# -> initialise Vault once. Prerequisites: AWS credentials for the target
# account, terraform/envs/demo/terraform.tfvars and backend.hcl filled in.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need aws terraform kubectl jq

[[ "${FINCORE_AWS:-}" == confirm ]] || die "this creates billable AWS resources; set FINCORE_AWS=confirm to proceed"
ENV_DIR="$ROOT/terraform/envs/demo"
[[ -f "$ENV_DIR/terraform.tfvars" && -f "$ENV_DIR/backend.hcl" ]] || die "fill in $ENV_DIR/terraform.tfvars and backend.hcl first"
log "AWS account $(aws sts get-caller-identity --query Account --output text), region $(aws configure get region || echo "?")"

log "1/4 Terraform state bucket (terraform/bootstrap)"
terraform -chdir="$ROOT/terraform/bootstrap" init -input=false >/dev/null
terraform -chdir="$ROOT/terraform/bootstrap" apply -input=false -auto-approve

log "2/4 demo environment (about 25 minutes: EKS and Aurora dominate)"
terraform -chdir="$ENV_DIR" init -input=false -backend-config=backend.hcl >/dev/null
tf_profile_args
terraform -chdir="$ENV_DIR" apply -input=false -auto-approve ${TF_PROFILE_ARGS[@]+"${TF_PROFILE_ARGS[@]}"}

log "3/4 kubeconfig"
export KUBECONFIG="$ROOT/.kube/aws-config"
aws eks update-kubeconfig --name "$(terraform -chdir="$ENV_DIR" output -raw cluster_name)" --kubeconfig "$KUBECONFIG" >/dev/null

log "4/4 waiting for every application (Vault is initialised as soon as it runs)"
vault_done=0
start=$SECONDS
until [[ "$(kubectl -n argocd get applications.argoproj.io -o json 2>/dev/null |
  jq '[.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")] | length')" == 0 ]]; do
  if [[ $vault_done == 0 && "$(kubectl -n vault get pod vault-0 -o jsonpath='{.status.containerStatuses[0].started}' 2>/dev/null)" == true ]]; then
    VAULT_INIT_FILE="$ROOT/.kube/aws-vault-init.json" "$ROOT/scripts/vault-init.sh"
    warn "move .kube/aws-vault-init.json (recovery keys) to offline storage now, then delete it"
    vault_done=1
  fi
  (( SECONDS - start > 2700 )) && die "applications not healthy after 45 minutes"
  sleep 20
done
kubectl -n argocd get applications.argoproj.io
ok "FinCore is up on AWS. Destroy with: FINCORE_AWS=confirm scripts/down.sh"
