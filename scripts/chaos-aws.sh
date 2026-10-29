#!/usr/bin/env bash
# AWS counterpart of scripts/chaos.sh: the two faults kind cannot reproduce
# faithfully. Disrupts a real environment, so it refuses to run without an
# explicit confirmation. Never run in this project (kind only); kept so the
# AWS experiments are code, reviewed with everything else.
#
#   FINCORE_CHAOS_AWS=confirm scripts/chaos-aws.sh az-loss       # FIS: the first AZ loses all traffic for 5 min
#   FINCORE_CHAOS_AWS=confirm scripts/chaos-aws.sh db-failover   # Aurora: promote the reader in the other AZ
#
# Watch Grafana (FinCore / SLOs) and Alertmanager while it runs; measure the
# client side with scripts/chaos.sh's probe if needed. Inputs come from the
# Terraform outputs of terraform/envs/demo.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need aws jq terraform

[[ "${FINCORE_CHAOS_AWS:-}" == confirm ]] || die "this disrupts a real AWS environment; set FINCORE_CHAOS_AWS=confirm to proceed"
out() { terraform -chdir="$ROOT/terraform/envs/demo" output -raw "$1"; }

case "${1:-}" in
  az-loss)
    template="$(out fis_az_loss_template_id)"
    log "starting FIS experiment from template $template"
    id="$(aws fis start-experiment --experiment-template-id "$template" --query 'experiment.id' --output text)"
    ok "experiment $id started"
    while :; do
      state="$(aws fis get-experiment --id "$id" --query 'experiment.state.status' --output text)"
      log "$(date -u +%H:%M:%S) $state"
      case "$state" in completed|stopped|failed) break ;; esac
      sleep 15
    done
    [[ "$state" == completed ]] || die "experiment ended as $state"
    ok "zone restored"
    ;;
  db-failover)
    cluster="$(out aurora_cluster_id)"
    writer() {
      aws rds describe-db-clusters --db-cluster-identifier "$cluster" \
        --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter].DBInstanceIdentifier' --output text
    }
    before="$(writer)"
    log "failing over $cluster (writer: $before)"
    aws rds failover-db-cluster --db-cluster-identifier "$cluster" >/dev/null
    start=$SECONDS
    until [[ "$(writer)" != "$before" ]] && \
      [[ "$(aws rds describe-db-clusters --db-cluster-identifier "$cluster" --query 'DBClusters[0].Status' --output text)" == available ]]; do
      (( SECONDS - start > 600 )) && die "failover not complete after 10 minutes"
      sleep 5
    done
    ok "new writer $(writer) after $(( SECONDS - start ))s"
    ;;
  *) die "usage: $0 az-loss|db-failover" ;;
esac
