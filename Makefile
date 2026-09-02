# Makefile — the operations CI performs, runnable by hand.
#
# The organising rule is congruence: a target here should do what the
# corresponding job in .github/workflows/ci.yml does, or it is worse than
# not existing. A `make lint` that passes while CI fails teaches people to
# distrust the Makefile and push instead, which is how the loop gets slow.
#
# Two things that used to break that rule, both fixed here:
#
#   - `ansible-lint ansible/ || true` swallowed every failure. CI does not.
#   - shellcheck ran over scripts/*.sh only. CI also lints every test
#     harness and every fake-bin shim, and asserts the executable bit.
#
# Where a target cannot match CI exactly it says so rather than pretending.
#
# Run `make` for the list.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

COMPOSE     := docker compose -f docker/dev/docker-compose.yml
CACERT      := docker/dev/tls/ca.crt
VAULT_ADDR  ?= https://127.0.0.1:8200

# Suites are discovered, not listed.
#
# CLAUDE.md warns that adding a suite under tests/ does not wire it into
# CI. That is unavoidable for the workflow, which has to enumerate jobs —
# but there is no reason for this file to go stale the same way, and
# `make check-ci-coverage` turns the gap into a failure rather than an
# omission nobody notices.
ALL_SUITES  := $(sort $(notdir $(patsubst %/,%,$(dir $(wildcard tests/*/run-tests.sh)))))

# integration needs a real cluster; cloud-apply-emulated needs terraform
# and moto. Everything else is shims and runs in seconds.
SLOW_SUITES := integration cloud-apply-emulated
FAST_SUITES := $(filter-out $(SLOW_SUITES),$(ALL_SUITES))

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
		/^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@printf '\n  \033[1msuites\033[0m  %s\n\n' "$(ALL_SUITES)"

##@ Local cluster

.PHONY: deploy
deploy: ## 3-node Raft cluster + monitoring (what CI's smoke test brings up)
	./scripts/bootstrap-dev-cluster.sh --with-monitoring

.PHONY: deploy-min
deploy-min: ## Just the cluster, no extras — fastest way to get a Vault
	./scripts/bootstrap-dev-cluster.sh

# Every flag bootstrap-dev-cluster.sh has, which makes this a superset of
# the integration suite rather than a match for it: that suite does not
# pass --with-oidc, because human login is covered by its own CI job. The
# header rule above applies -- say where a target diverges from CI rather
# than implying it does not.
#
# --with-mysql was missing here while the integration suite passed it, so
# `make deploy-full` produced a cluster with no second database engine
# while the help text claimed otherwise. A local reproduction quietly
# narrower than the thing it reproduces is worse than no target at all.
.PHONY: deploy-full
deploy-full: ## Every optional service (a superset of the integration suite)
	./scripts/bootstrap-dev-cluster.sh --with-monitoring --with-postgres \
		--with-mysql --with-oidc --with-audit --with-agent

.PHONY: status
status: ## Compose state plus each node's seal/HA status
	@$(COMPOSE) ps
	@for p in 8200 8210 8220; do \
		printf '\n vault on %s: ' "$$p"; \
		curl -s --cacert $(CACERT) "https://127.0.0.1:$$p/v1/sys/health?standbyok=true" \
			| jq -c '{sealed, standby, version}' 2>/dev/null || echo unreachable; \
	done
	@printf '\n'

.PHONY: peers
peers: ## Raft peers and who holds leadership
	@VAULT_ADDR=$(VAULT_ADDR) VAULT_CACERT=$(CACERT) \
		vault operator raft list-peers 2>/dev/null || \
		echo "needs VAULT_TOKEN — export the root token from bootstrap first"

.PHONY: logs
logs: ## Follow every container's logs
	@$(COMPOSE) logs -f --tail=50

.PHONY: destroy
destroy: ## Tear the cluster down, volumes included
	$(COMPOSE) down -v

##@ Day-two operations

.PHONY: snapshot
snapshot: ## Take a Raft snapshot into ./snapshots
	./scripts/snapshot.sh --cloud none --output-dir ./snapshots

.PHONY: dr-drill
dr-drill: ## Snapshot, destroy a node and its storage, restore, verify
	./scripts/dr-drill.sh

.PHONY: verify-audit
verify-audit: ## Check the audit trail has not been edited
	./scripts/verify-audit-chain.sh

.PHONY: rotate-secret-id
rotate-secret-id: ## Issue a fresh AppRole secret_id (ROLE=name)
	@[ -n "$(ROLE)" ] || { echo "usage: make rotate-secret-id ROLE=<approle-name>"; exit 2; }
	./scripts/rotate-secret-id.sh --role $(ROLE)

##@ Tests

.PHONY: test
test: test-fast ## Every suite that needs no cluster (seconds)

.PHONY: test-fast
test-fast: ## Shim suites only — no Docker, no credentials
	@fail=0; for s in $(FAST_SUITES); do \
		printf '\n\033[36m=== %s ===\033[0m\n' "$$s"; \
		./tests/$$s/run-tests.sh || fail=1; \
	done; \
	[ $$fail -eq 0 ] || { printf '\n\033[31mone or more suites failed\033[0m\n'; exit 1; }

.PHONY: test-suite
test-suite: ## Run one suite (SUITE=snapshot)
	@[ -n "$(SUITE)" ] || { echo "usage: make test-suite SUITE=<name>"; echo "  $(ALL_SUITES)"; exit 2; }
	@[ -x tests/$(SUITE)/run-tests.sh ] || { echo "no such suite: $(SUITE)"; exit 2; }
	./tests/$(SUITE)/run-tests.sh

.PHONY: test-cluster
test-cluster: ## The integration suite against a real 3-node cluster (minutes)
	./tests/integration/run-tests.sh

.PHONY: test-all
test-all: test-fast test-cluster ## Everything, including the real cluster

##@ Cloud, without spending anything

.PHONY: tf-test
tf-test: ## terraform fmt/validate/test for both profiles (mocked providers)
	terraform fmt -check -recursive terraform/
	terraform -chdir=terraform/aws init -backend=false
	terraform -chdir=terraform/aws validate
	terraform -chdir=terraform/aws test
	terraform -chdir=terraform/azure init -backend=false
	terraform -chdir=terraform/azure validate
	terraform -chdir=terraform/azure test

.PHONY: preflight-static
preflight-static: ## Cross-layer checks an apply would otherwise discover
	./tests/preflight-static/run-tests.sh

.PHONY: emulated-apply
emulated-apply: ## Real terraform apply against an emulated AWS API
	./tests/cloud-apply-emulated/run-tests.sh

.PHONY: preflight-cloud
preflight-cloud: ## Pre-apply checks needing credentials (CLOUD=aws|azure)
	@[ -n "$(CLOUD)" ] || { echo "usage: make preflight-cloud CLOUD=aws|azure"; exit 2; }
	./scripts/preflight-cloud.sh --cloud $(CLOUD)

##@ Lint — these mirror CI exactly

.PHONY: fmt
fmt: ## Rewrite Terraform formatting in place
	terraform fmt -recursive terraform/

.PHONY: lint
lint: lint-terraform lint-ansible lint-shell lint-markdown docs-check check-ci-coverage ## Every static check CI runs

.PHONY: lint-terraform
lint-terraform: ## terraform fmt -check and validate
	terraform fmt -check -recursive terraform/
	terraform -chdir=terraform/aws init -backend=false
	terraform -chdir=terraform/aws validate
	terraform -chdir=terraform/azure init -backend=false
	terraform -chdir=terraform/azure validate

.PHONY: lint-ansible
lint-ansible: ## ansible-lint and a playbook syntax check
	ANSIBLE_ROLES_PATH=$(CURDIR)/ansible/roles ansible-lint ansible/
	cd ansible && ansible-playbook --syntax-check -i inventory/local playbooks/site.yml

.PHONY: lint-shell
lint-shell: check-exec ## shellcheck over scripts AND every test harness
	shellcheck scripts/*.sh
	@mapfile -t harness < <(git ls-files 'tests/**/*.sh' 'tests/*/fake-bin/*'); \
		printf 'Linting %d test files\n' "$${#harness[@]}"; \
		[ "$${#harness[@]}" -gt 0 ] || { echo "no test scripts found — the glob is wrong"; exit 1; }; \
		shellcheck -s bash "$${harness[@]}"
	./tests/lint/run-tests.sh

.PHONY: check-exec
check-exec: ## Every shell script must be mode 100755
	@non_exec="$$(git ls-files -s '*.sh' 'tests/*/fake-bin/*' | grep -v '^100755' || true)"; \
		if [ -n "$$non_exec" ]; then \
			echo "These scripts are missing the executable bit:"; \
			echo "$$non_exec"; \
			echo "Fix with: git update-index --chmod=+x <path>"; \
			exit 1; \
		fi

.PHONY: lint-markdown
lint-markdown: ## markdownlint over every .md
	@# CI uses DavidAnson/markdownlint-cli2-action, which pins the version.
	@# npx resolves whatever is current, so a local pass is strong evidence
	@# and not a guarantee. Said here rather than implied.
	@command -v npx >/dev/null 2>&1 || { 		echo "npx not found — markdownlint runs in CI regardless"; exit 1; }
	npx --yes markdownlint-cli2 "**/*.md"

.PHONY: check-ci-coverage
check-ci-coverage: ## Fail if a suite under tests/ has no CI job
	@missing=""; \
		for s in $(ALL_SUITES); do \
			grep -q "tests/$$s/run-tests.sh" .github/workflows/ci.yml || missing="$$missing $$s"; \
		done; \
		if [ -n "$$missing" ]; then \
			echo "These suites exist but no CI job runs them:$$missing"; \
			echo "Adding a suite under tests/ does not wire it into CI — add the job too."; \
			exit 1; \
		fi; \
		echo "all $(words $(ALL_SUITES)) suites are wired into CI"

##@ Docs

.PHONY: docs
docs: ## Regenerate docs/README.md from the doc set
	@./scripts/generate-docs-index.sh

.PHONY: docs-check
docs-check: ## Fail if docs/README.md is stale, and check the generator
	@./scripts/generate-docs-index.sh --check
	@./tests/docs-index/run-tests.sh
