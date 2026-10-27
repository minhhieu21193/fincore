# FinCore — common tasks. Every target is a thin wrapper over scripts/.
SHELL := bash
TEST_DB_PORT ?= 55432
export TEST_DATABASE_URL ?= postgres://postgres:test@localhost:$(TEST_DB_PORT)/postgres?sslmode=disable

.PHONY: help
help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: test-db
test-db: ## Start a throwaway PostgreSQL 17 for Go tests (docker)
	@docker start fincore-testpg >/dev/null 2>&1 || docker run -d --name fincore-testpg -e POSTGRES_PASSWORD=test -p $(TEST_DB_PORT):5432 \
	  postgres:17.11-alpine3.23@sha256:01ea903aa65deb58eb49d6e09d859ecff63a6bb7d61feca55f2abad71d08f72a >/dev/null
	@until docker exec fincore-testpg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; echo "test database ready on :$(TEST_DB_PORT)"

.PHONY: test
test: test-db ## Go tests incl. PostgreSQL-backed invariant tests
	go test -race -count=1 ./...

.PHONY: lint
lint: ## golangci-lint
	golangci-lint run ./...

.PHONY: check
check: test-db ## All static checks (same as CI)
	scripts/check.sh --all

.PHONY: kind-up
kind-up: ## Create/update the local platform on kind
	scripts/kind-up.sh

.PHONY: kind-down
kind-down: ## Delete the kind cluster (PURGE=1 also removes the local registry and PKI)
	scripts/kind-down.sh $(if $(PURGE),--purge)

.PHONY: e2e
e2e: ## Acceptance: payment flows API -> ledger -> outbox -> queue -> webhook
	scripts/e2e.sh

.PHONY: demo-good-release
demo-good-release: ## Healthy build is promoted 10 -> 30 -> 60 -> 100% (commits to the current branch, then reverts)
	scripts/demo-good-release.sh

.PHONY: demo-bad-release
demo-bad-release: ## Bad build is rolled back automatically (commits to the current branch, then reverts)
	scripts/demo-bad-release.sh

.PHONY: demo-policies
demo-policies: ## Phase 2 B1: unsigned, unattested, foreign and root workloads are rejected at admission
	scripts/demo-policies.sh

.PHONY: demo-netpol
demo-netpol: ## Phase 2 B3: NetworkPolicies isolate the cardholder-data zone
	scripts/demo-netpol.sh

.PHONY: demo-rotation
demo-rotation: ## Phase 2 B2: the ledger's Vault-issued DB credentials rotate without a restart
	scripts/demo-rotation.sh

.PHONY: demo-observability
demo-observability: ## Phase 3 C1: one payment followed from its trace to its logs to its ledger entry; dashboards have data
	scripts/demo-observability.sh

.PHONY: vault-init
vault-init: ## One-time Vault initialisation (run by kind-up; on EKS run it once by hand)
	scripts/vault-init.sh

.PHONY: loadtest
loadtest: ## k6 load test against a port-forwarded payments-api (RPS=50 DURATION=2m)
	k6 run -e TARGET=$${TARGET:-http://localhost:8080} -e RPS=$${RPS:-50} -e DURATION=$${DURATION:-2m} loadtest/payments.js
