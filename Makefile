.PHONY: deploy status destroy lint test docs

deploy: ## Bring up the local 3-node Vault cluster
	sudo docker-compose -f docker/dev/docker-compose.yml up -d --build

status: ## Check status of the local cluster
	sudo docker-compose -f docker/dev/docker-compose.yml ps
	curl -s http://localhost:8200/v1/sys/health | jq . || true

destroy: ## Tear down the local cluster
	sudo docker-compose -f docker/dev/docker-compose.yml down -v

lint: ## Run all lint/format/validate checks
	terraform fmt -check -recursive terraform/
	terraform -chdir=terraform/aws validate
	terraform -chdir=terraform/azure validate
	ansible-lint ansible/ || true
	shellcheck scripts/*.sh

test: ## Run automated tests (placeholder)
	@echo "TODO: add Terraform/Ansible integration tests"

docs: ## List doc set (placeholder for future doc generation)
	@ls docs/
