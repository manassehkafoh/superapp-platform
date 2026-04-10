##############################################################################
# SuperApp Monorepo — Makefile
# Common developer tasks in one place. Run `make help` to see all targets.
##############################################################################

.DEFAULT_GOAL := help
.PHONY: help build test test-unit test-integration lint format clean \
        docker-build docker-push local-up local-down \
        tf-init tf-plan tf-apply deploy-dev deploy-staging \
        argocd-sync k8s-status security-scan coverage

SERVICES       := identity-api payment-api wallet-api account-api notification-api api-gateway
REGISTRY       := acrsuperapp.azurecr.io
GIT_SHA        := $(shell git rev-parse --short HEAD)
ENVIRONMENT    ?= dev
PARALLELISM    ?= 4

# ── Colours ──────────────────────────────────────────────────────────────────
CYAN  := \033[0;36m
RESET := \033[0m
BOLD  := \033[1m

##@ General

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\n$(BOLD)SuperApp Monorepo — Available targets$(RESET)\n\n"} \
	     /^[a-zA-Z_0-9-]+:.*?##/ { printf "  $(CYAN)%-25s$(RESET) %s\n", $$1, $$2 } \
	     /^##@/ { printf "\n$(BOLD)%s$(RESET)\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ .NET Build & Test

build: ## Build entire solution
	@echo "$(CYAN)▶ Building solution...$(RESET)"
	dotnet build SuperApp.sln -c Release --no-restore

restore: ## Restore all NuGet packages
	dotnet restore SuperApp.sln

test: test-unit test-integration ## Run all tests

test-unit: ## Run unit tests only (fast, no external deps)
	@echo "$(CYAN)▶ Unit tests...$(RESET)"
	dotnet test tests/unit \
	  --no-restore \
	  --filter "Category!=Integration" \
	  --collect:"XPlat Code Coverage" \
	  --results-directory ./TestResults \
	  --logger "console;verbosity=minimal"

test-integration: ## Run integration tests (requires Docker)
	@echo "$(CYAN)▶ Integration tests (requires Docker)...$(RESET)"
	dotnet test tests/integration \
	  --no-restore \
	  --filter "Category=Integration" \
	  --collect:"XPlat Code Coverage" \
	  --results-directory ./TestResults \
	  --logger "console;verbosity=minimal"

coverage: test-unit ## Generate HTML coverage report (opens browser)
	@echo "$(CYAN)▶ Generating coverage report...$(RESET)"
	reportgenerator \
	  -reports:"TestResults/*/coverage.cobertura.xml" \
	  -targetdir:"coverage-report" \
	  -reporttypes:Html
	@echo "Opening coverage report..."
	open coverage-report/index.html || xdg-open coverage-report/index.html

lint: ## Run code analysis (warnings as errors)
	dotnet build SuperApp.sln -c Release /p:TreatWarningsAsErrors=true --no-restore

format: ## Format all C# files
	dotnet format SuperApp.sln

clean: ## Clean all build artifacts
	dotnet clean SuperApp.sln
	find . -type d -name bin  -not -path "./.git/*" | xargs rm -rf
	find . -type d -name obj  -not -path "./.git/*" | xargs rm -rf
	rm -rf TestResults coverage-report artifacts

##@ Docker

docker-build: ## Build Docker images for all services (or SERVICE=payment-api for one)
ifdef SERVICE
	@echo "$(CYAN)▶ Building $(SERVICE)...$(RESET)"
	docker build -f src/services/$(SERVICE)/Dockerfile \
	  -t $(REGISTRY)/$(SERVICE):$(GIT_SHA) \
	  -t $(REGISTRY)/$(SERVICE):latest \
	  .
else
	@for svc in $(SERVICES); do \
	  echo "$(CYAN)▶ Building $$svc...$(RESET)"; \
	  docker build -f src/services/$$svc/Dockerfile \
	    -t $(REGISTRY)/$$svc:$(GIT_SHA) \
	    -t $(REGISTRY)/$$svc:latest . || exit 1; \
	done
endif

docker-push: ## Push images to ACR (requires az acr login)
	az acr login --name acrsuperapp
ifdef SERVICE
	docker push $(REGISTRY)/$(SERVICE):$(GIT_SHA)
	docker push $(REGISTRY)/$(SERVICE):latest
else
	@for svc in $(SERVICES); do \
	  docker push $(REGISTRY)/$$svc:$(GIT_SHA); \
	  docker push $(REGISTRY)/$$svc:latest; \
	done
endif

##@ Local Development

local-up: ## Start local infrastructure (k3d cluster + Redis + Kafka + SQL)
	@echo "$(CYAN)▶ Starting local infrastructure...$(RESET)"
	./platform/scripts/local-infra-up.sh

local-down: ## Stop and clean up local infrastructure
	k3d cluster delete superapp-local 2>/dev/null || true
	docker compose -f build/docker/docker-compose.local.yml down -v 2>/dev/null || true

run: ## Run a service locally with hot reload (SERVICE=payment-api)
ifndef SERVICE
	$(error SERVICE is not set. Usage: make run SERVICE=payment-api)
endif
	cd src/services/$(SERVICE)/src && dotnet watch run

##@ Security

security-scan: ## Run TruffleHog + Trivy locally
	@echo "$(CYAN)▶ Scanning for secrets (TruffleHog)...$(RESET)"
	trufflehog git file://. --only-verified || true
	@echo "$(CYAN)▶ IaC security scan (Trivy)...$(RESET)"
	trivy config platform/ --severity CRITICAL,HIGH

vuln-scan: ## Scan NuGet packages for vulnerabilities
	dotnet list SuperApp.sln package --vulnerable --include-transitive

##@ Terraform / Infrastructure

tf-init: ## terraform init for ENVIRONMENT (default: dev)
	cd platform/terraform && \
	terraform init \
	  -backend-config="key=$(ENVIRONMENT)/terraform.tfstate" \
	  -backend-config="resource_group_name=rg-superapp-tfstate" \
	  -backend-config="storage_account_name=stsuperappterraform" \
	  -backend-config="container_name=tfstate"

tf-plan: tf-init ## terraform plan for ENVIRONMENT
	cd platform/terraform && \
	terraform plan \
	  -var-file="environments/$(ENVIRONMENT)/terraform.tfvars" \
	  -parallelism=$(PARALLELISM) \
	  -out=tfplan-$(ENVIRONMENT)

tf-apply: ## terraform apply for ENVIRONMENT (requires tf-plan first)
	@[ "$(ENVIRONMENT)" != "prod" ] || \
	  (echo "❌ Use deploy.sh for production. make tf-apply is blocked on prod." && exit 1)
	cd platform/terraform && \
	terraform apply -auto-approve tfplan-$(ENVIRONMENT)

tf-destroy: ## terraform destroy for dev ONLY
	@[ "$(ENVIRONMENT)" = "dev" ] || (echo "❌ destroy only allowed on dev" && exit 1)
	cd platform/terraform && \
	terraform destroy \
	  -var-file="environments/dev/terraform.tfvars" \
	  -auto-approve

##@ Kubernetes / GitOps

argocd-sync: ## Sync all ArgoCD apps for ENVIRONMENT
	@for svc in $(SERVICES); do \
	  argocd app sync $(ENVIRONMENT)-$$svc --force --prune 2>/dev/null || true; \
	done

k8s-status: ## Show pod status for superapp-services namespace
	kubectl get pods -n superapp-services -o wide
	@echo ""
	kubectl get pods -n superapp-gateway -o wide 2>/dev/null || true

k8s-logs: ## Follow logs for a service (SERVICE=payment-api)
ifndef SERVICE
	$(error SERVICE is not set. Usage: make k8s-logs SERVICE=payment-api)
endif
	kubectl logs -l app=$(SERVICE) -n superapp-services -f --tail=100

rollback: ## Rollback a service in ENVIRONMENT (SERVICE=payment-api ENVIRONMENT=prod)
ifndef SERVICE
	$(error SERVICE is not set. Usage: make rollback SERVICE=payment-api ENVIRONMENT=prod)
endif
	argocd app rollback $(ENVIRONMENT)-$(SERVICE)

##@ End-to-End Deployment

deploy-dev: ## Full deploy to dev via deploy.sh
	./platform/scripts/deploy.sh --environment dev

deploy-staging: ## Full deploy to staging via deploy.sh
	./platform/scripts/deploy.sh --environment staging

deploy-prod: ## Deploy to production (requires ITSM ticket)
	./platform/scripts/deploy.sh --environment prod

deploy-dry-run: ## Dry-run plan for ENVIRONMENT
	./platform/scripts/deploy.sh --environment $(ENVIRONMENT) --dry-run

##@ Monitoring

monitoring-up: ## Start full Grafana + ELK monitoring stack locally
	@echo "$(CYAN)▶ Starting monitoring stack...$(RESET)"
	docker compose -f build/docker/docker-compose.monitoring.yml up -d --wait
	@echo ""
	@echo "  Grafana:       http://localhost:3000  (admin/SuperApp@Grafana2024)"
	@echo "  Kibana:        http://localhost:5601  (elastic/SuperApp@Elastic2024)"
	@echo "  Prometheus:    http://localhost:9090"
	@echo "  Elasticsearch: http://localhost:9200"

monitoring-down: ## Stop monitoring stack
	docker compose -f build/docker/docker-compose.monitoring.yml down

monitoring-status: ## Check status of monitoring services
	docker compose -f build/docker/docker-compose.monitoring.yml ps

elk-setup: ## Initialise Elasticsearch templates and ILM policies
	@echo "$(CYAN)▶ Setting up Elasticsearch...$(RESET)"
	@sleep 10  # Wait for ES to be ready
	curl -s -u elastic:$${ELASTIC_PASSWORD:-SuperApp@Elastic2024} \
	  -X PUT http://localhost:9200/_index_template/superapp-kpi \
	  -H "Content-Type: application/json" \
	  -d @platform/monitoring/elk/elasticsearch/templates/superapp-kpi-template.json
	curl -s -u elastic:$${ELASTIC_PASSWORD:-SuperApp@Elastic2024} \
	  -X PUT http://localhost:9200/_ilm/policy/superapp-kpi-ilm \
	  -H "Content-Type: application/json" \
	  -d @platform/monitoring/elk/elasticsearch/ilm/superapp-kpi-ilm.json
	@echo "✅ Elasticsearch configured"

grafana-dashboards: ## Import Grafana dashboards
	@echo "$(CYAN)▶ Dashboards are auto-provisioned via volume mount$(RESET)"
	@echo "  Open: http://localhost:3000/dashboards"
	@echo "  KPI Dashboard: SuperApp Mobile — Republic Bank Ghana KPI Dashboard"
