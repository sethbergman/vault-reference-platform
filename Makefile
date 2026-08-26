.PHONY: deploy status destroy lint test docs docs-check

deploy: ## Bring up the local 3-node Vault cluster + Prometheus/Grafana
	./scripts/bootstrap-dev-cluster.sh --with-monitoring

status: ## Check status of the local cluster
	docker compose -f docker/dev/docker-compose.yml ps
	curl -s --cacert docker/dev/tls/ca.crt \
	  https://localhost:8200/v1/sys/health | jq . || true

destroy: ## Tear down the local cluster
	docker compose -f docker/dev/docker-compose.yml down -v

lint: ## Run all lint/format/validate checks
	terraform fmt -check -recursive terraform/
	terraform -chdir=terraform/aws validate
	terraform -chdir=terraform/azure validate
	ansible-lint ansible/ || true
	shellcheck scripts/*.sh
	./scripts/generate-docs-index.sh --check

test: ## Run the disaster recovery restore drill
	./scripts/dr-drill.sh

docs: ## Regenerate docs/README.md from the doc set
	@./scripts/generate-docs-index.sh

docs-check: ## Fail if docs/README.md is stale (what CI runs)
	@./scripts/generate-docs-index.sh --check
