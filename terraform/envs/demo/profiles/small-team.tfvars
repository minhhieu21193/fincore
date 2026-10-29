# Small-team profile: the same platform for a team that cannot staff Vault.
# Layer it over terraform.tfvars (scripts/up.sh does this with
# FINCORE_PROFILE=small-team):
#
#   terraform plan -var-file=terraform.tfvars -var-file=profiles/small-team.tfvars
#
# What it changes and costs: docs/cost.md (small-team profile). What it gives
# up: docs/compliance-mapping.md (small-team profile).

# One NAT gateway for all three AZs (also the demo default): losing the NAT's
# AZ cuts internet egress (webhooks to merchants, image pulls outside ECR)
# until it returns; AWS APIs keep working through the VPC endpoints.
single_nat_gateway = true

# Two system nodes in two AZs: enough for Argo CD, Karpenter and CoreDNS to
# survive a node loss once Vault (which needs three) is gone.
system_node_count = 2

# No Vault HA: the ledger's database password lives in Secrets Manager (CDE
# key) and reaches the pod through External Secrets, like payments-api's.
secrets_backend = "secrets-manager"
