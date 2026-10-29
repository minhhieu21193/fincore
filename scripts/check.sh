#!/usr/bin/env bash
# Every static check, identical locally and in CI.
#
#   scripts/check.sh            # everything
#   scripts/check.sh --go       # go vet, go test, golangci-lint
#   scripts/check.sh --static   # terraform, checkov, helm, kubeconform, kyverno test, promtool, actionlint, shellcheck
#
# Go tests that need PostgreSQL run when TEST_DATABASE_URL is set
# (make test-db starts one in docker).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

MODE="${1:---all}"
K8S_VERSION=1.36.0
# Custom resources are validated against schemas generated from the CRDs our
# pinned charts ship (scripts/ci/crd-schemas.sh); the community catalog at a
# pinned commit is the fallback for CRDs installed outside the rendered apps.
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

# Offline module tests (mocked providers, no AWS calls): which KMS key each
# workload may use, and the key policies of each data domain.
terraform_tests() {
  local d
  for d in terraform/modules/*/; do
    [[ -d "$d/tests" ]] || continue
    (cd "$d" && terraform init -backend=false -input=false >/dev/null && terraform test -no-color) || return 1
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
  "${lint[@]}" policies &&
  "${lint[@]}" dashboards &&
  "${lint[@]}" gitops/platform/slo &&
  "${lint[@]}" gitops/platform/backups -f gitops/envs/kind/values/backups.yaml &&
  "${lint[@]}" gitops/platform/backups --set uploader=aws-cli &&
  "${lint[@]}" policies --set signature.mode=keyless &&
  "${lint[@]}" gitops/apps/fincore-base -f gitops/apps/cde-base/values.yaml &&
  "${lint[@]}" gitops/bootstrap/app-of-apps -f gitops/envs/kind/app-of-apps.yaml &&
  "${lint[@]}" gitops/bootstrap/app-of-apps -f gitops/envs/aws/app-of-apps.yaml -f gitops/ci/aws-cluster.example.yaml &&
  "${lint[@]}" gitops/bootstrap/app-of-apps -f gitops/envs/aws/app-of-apps.yaml -f gitops/ci/aws-cluster.example.yaml -f gitops/envs/aws/secrets-manager/app-of-apps.yaml
}

kubeconform_envs() {
  local out env
  out="$(mktemp -d)"
  for env in kind aws; do
    scripts/render.sh "$env" "$out/$env" >/dev/null || return 1
  done
  # AWS without Vault (small-team profile, Terraform secrets_backend = "secrets-manager").
  scripts/render.sh aws "$out/aws-secrets-manager" secrets-manager >/dev/null || return 1
  scripts/ci/crd-schemas.sh "$out/kind" "$out/aws" "$out/aws-secrets-manager" "$out/schemas" || return 1
  # Security invariant: the Vault injector fails closed in every environment.
  for env in kind aws; do
    [[ "$(yq 'select(.kind == "MutatingWebhookConfiguration" and .metadata.name == "vault-agent-injector-cfg") | .webhooks[].failurePolicy' "$out/$env/vault.yaml")" == Fail ]] ||
      { echo "vault injector webhook must have failurePolicy Fail ($env)"; return 1; }
  done
  # Without Vault nothing may still expect it: no Vault apps, no agent on the ledger.
  local sm="$out/aws-secrets-manager"
  if [[ -e "$sm/vault.yaml" || -e "$sm/vault-config.yaml" ]] || grep -q 'vault.hashicorp.com/agent-inject' "$sm"/*.yaml; then
    echo "aws (secrets-manager) still renders Vault or a Vault Agent"; return 1
  fi
  [[ "$(yq 'select(.kind == "Rollout") | .spec.template.spec.containers[0].env[] | select(.name == "DB_PASSWORD") | .valueFrom.secretKeyRef.name' "$sm/ledger.yaml")" == ledger-db ]] ||
    { echo "aws (secrets-manager): the ledger must read DB_PASSWORD from Secret ledger-db"; return 1; }
  # AWS: no backup may contain the cardholder-data zone's Secrets, and the
  # zone's nodes encrypt their disks with the CDE key (general nodes: platform key).
  local schedules
  schedules="$(yq -o=json -I=0 'select(.kind == "Schedule") | .spec.template' "$out/aws/velero.yaml")"
  if jq -e -s 'any(.[]; (.includedNamespaces // [] | index("fincore-cde")) and (.excludedResources // [] | index("secrets") | not))' <<<"$schedules" >/dev/null; then
    echo "aws: a Velero schedule backs up fincore-cde Secrets"; return 1
  fi
  [[ "$(yq 'select(.kind == "EC2NodeClass" and .metadata.name == "cde") | .spec.blockDeviceMappings[0].ebs.kmsKeyID' "$out/aws/karpenter-nodepools.yaml")" == "$(yq '.cluster.cdeKmsKeyArn' gitops/ci/aws-cluster.example.yaml)" &&
     "$(yq 'select(.kind == "EC2NodeClass" and .metadata.name != "cde") | .spec.blockDeviceMappings[0].ebs.kmsKeyID' "$out/aws/karpenter-nodepools.yaml")" == "$(yq '.cluster.platformKmsKeyArn' gitops/ci/aws-cluster.example.yaml)" ]] ||
    { echo "aws: EC2NodeClass root volumes must use the CDE key (cde) and the platform key (general)"; return 1; }
  for env in kind aws aws-secrets-manager; do
    kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" \
      -schema-location default \
      -schema-location "$out/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
      -schema-location "$CRD_SCHEMAS" \
      -skip CustomResourceDefinition \
      "$out/$env" gitops/bootstrap/kind/gitserver.yaml || return 1
  done
  rm -rf "$out"
}

# Admission policies against compliant and violating fixtures (policies/tests).
policy_tests() {
  local out
  out="$(mktemp -d)"
  cp policies/tests/kyverno-test.yaml policies/tests/resources.yaml policies/tests/values.yaml "$out/"
  helm template policies policies | yq 'select(.kind == "ValidatingPolicy")' > "$out/policies.yaml" || return 1
  kyverno test "$out" || return 1
  rm -rf "$out"
}

# The committed dashboard JSON is exactly what dashboards/generate.py produces.
dashboards_check() {
  local out
  out="$(mktemp -d)"
  python3 dashboards/generate.py "$out" && diff -r dashboards/json "$out" || return 1
  rm -rf "$out"
}

static_checks() {
  need terraform tflint checkov helm yq jq kubeconform kyverno actionlint shellcheck python3 promtool
  run "terraform fmt" terraform fmt -check -recursive terraform
  run "terraform validate" terraform_validate
  run "terraform test (modules, mocked providers)" terraform_tests
  run "tflint" tflint_all
  run "checkov" checkov --config-file .checkov.yaml --quiet --compact
  run "helm lint" helm_lint
  run "kubeconform (kind + aws, rendered as Argo CD would)" kubeconform_envs
  run "kyverno test (admission policies)" policy_tests
  run "dashboards up to date" dashboards_check
  run "promtool (SLO rules and alert tests)" bash -c \
    "promtool check rules gitops/platform/slo/rules/*.yaml && promtool test rules gitops/platform/slo/tests/*.test.yaml"
  run "actionlint" actionlint
  run "shellcheck" shellcheck -x scripts/*.sh scripts/ci/*.sh
  run "shellcheck (in-cluster scripts)" shellcheck -s sh gitops/platform/vault-config/files/configure.sh
}

case "$MODE" in
  --go) go_checks ;;
  --static) static_checks ;;
  --all) go_checks; static_checks ;;
  *) die "usage: $0 [--all|--go|--static]" ;;
esac

echo
if [[ ${#FAILED[@]} -eq 0 ]]; then ok "ALL CHECKS PASSED"; else die "failed: ${FAILED[*]}"; fi
