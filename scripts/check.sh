#!/usr/bin/env bash
# Every static check, identical locally and in CI.
#
#   scripts/check.sh            # everything
#   scripts/check.sh --go       # go vet, go test, golangci-lint
#   scripts/check.sh --static   # terraform, checkov, helm, kubeconform, actionlint, shellcheck
#
# Go tests that need PostgreSQL run when TEST_DATABASE_URL is set
# (make test-db starts one in docker).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

MODE="${1:---all}"
K8S_VERSION=1.36.0
# Pinned commit of the community CRD JSON-schema catalog (Rollouts, ExternalSecrets, ...).
CRD_SCHEMAS="https://raw.githubusercontent.com/datreeio/CRDs-catalog/3eb90d47aba8d61919d4419dd38301536e32a94b/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
FAILED=()

run() { # name, command...
  local name="$1"; shift
  log "$name"
  if "$@"; then ok "$name"; else warn "$name FAILED"; FAILED+=("$name"); fi
}

go_checks() {
  need go golangci-lint
  run "go vet" go vet ./...
  if [[ -n "${TEST_DATABASE_URL:-}" ]]; then
    run "go test (race, with PostgreSQL)" go test -race -count=1 ./...
  else
    warn "TEST_DATABASE_URL not set: PostgreSQL-backed tests are skipped (run: make test-db)"
    run "go test (race)" go test -race -count=1 ./...
  fi
  run "golangci-lint" golangci-lint run ./...
}

terraform_validate() {
  local root
  for root in terraform/bootstrap terraform/envs/demo; do
    (cd "$root" && terraform init -backend=false -input=false -lockfile=readonly >/dev/null && terraform validate -no-color) || return 1
  done
}

tflint_all() {
  local d
  tflint --init --config "$ROOT/terraform/.tflint.hcl" >/dev/null
  for d in terraform/bootstrap terraform/envs/demo terraform/modules/*; do
    tflint --chdir "$d" --config "$ROOT/terraform/.tflint.hcl" || return 1
  done
}

helm_lint() {
  local lint=(helm lint --quiet --kube-version "$K8S_VERSION")
  "${lint[@]}" gitops/charts/fincore-service -f gitops/apps/payments-api/values.yaml -f gitops/envs/kind/values/payments-api.yaml &&
  "${lint[@]}" gitops/charts/fincore-service -f gitops/apps/notifier/values.yaml -f gitops/envs/aws/values/notifier.yaml --set image.repository=lint &&
  "${lint[@]}" gitops/apps/fincore-base &&
  "${lint[@]}" gitops/apps/traffic-generator &&
  "${lint[@]}" gitops/platform/secret-stores &&
  "${lint[@]}" gitops/platform/secret-stores --set provider=aws &&
  "${lint[@]}" gitops/platform/cluster-issuers &&
  "${lint[@]}" gitops/platform/karpenter-nodepools --set clusterName=lint --set nodeRole=lint &&
  "${lint[@]}" gitops/bootstrap/app-of-apps -f gitops/envs/kind/app-of-apps.yaml &&
  "${lint[@]}" gitops/bootstrap/app-of-apps -f gitops/envs/aws/app-of-apps.yaml -f gitops/ci/aws-cluster.example.yaml
}

kubeconform_envs() {
  local out env
  out="$(mktemp -d)"
  for env in kind aws; do
    scripts/render.sh "$env" "$out/$env" >/dev/null || return 1
    kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" \
      -schema-location default -schema-location "$CRD_SCHEMAS" \
      -skip CustomResourceDefinition \
      "$out/$env" gitops/bootstrap/kind/gitserver.yaml || return 1
  done
  rm -rf "$out"
}

static_checks() {
  need terraform tflint checkov helm yq kubeconform actionlint shellcheck
  run "terraform fmt" terraform fmt -check -recursive terraform
  run "terraform validate" terraform_validate
  run "tflint" tflint_all
  run "checkov" checkov --config-file .checkov.yaml --quiet --compact
  run "helm lint" helm_lint
  run "kubeconform (kind + aws, rendered as Argo CD would)" kubeconform_envs
  run "actionlint" actionlint
  run "shellcheck" shellcheck -x scripts/*.sh scripts/ci/*.sh
}

case "$MODE" in
  --go) go_checks ;;
  --static) static_checks ;;
  --all) go_checks; static_checks ;;
  *) die "usage: $0 [--all|--go|--static]" ;;
esac

echo
if [[ ${#FAILED[@]} -eq 0 ]]; then ok "ALL CHECKS PASSED"; else die "failed: ${FAILED[*]}"; fi
