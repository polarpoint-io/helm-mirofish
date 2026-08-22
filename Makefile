# MiroFish-Offline on Kubernetes — local build and validation.

SHELL         := /bin/bash
.DEFAULT_GOAL := help

CHART         := charts/mirofish-offline
CHART_NAME    := mirofish-offline
UPSTREAM_REPO := https://github.com/nikmcfly/MiroFish-Offline.git
UPSTREAM_REF  := $(shell tr -d '[:space:]' < UPSTREAM_REF)
UPSTREAM_DIR  := upstream

REGISTRY      ?= ghcr.io
OWNER         ?= polarpoint-io
TAG           ?= dev
API_IMAGE     := $(REGISTRY)/$(OWNER)/mirofish-offline-api:$(TAG)
WEB_IMAGE     := $(REGISTRY)/$(OWNER)/mirofish-offline-web:$(TAG)

NAMESPACE     ?= mirofish
RELEASE       ?= mirofish
KUBE_VERSIONS := 1.27.0 1.29.0 1.31.0

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- upstream --
.PHONY: upstream
upstream: ## Clone/refresh the pinned upstream source into ./upstream
	@if [ ! -d "$(UPSTREAM_DIR)/.git" ]; then \
	  echo "Cloning $(UPSTREAM_REPO)"; \
	  git clone --filter=blob:none "$(UPSTREAM_REPO)" "$(UPSTREAM_DIR)"; \
	fi
	@cd "$(UPSTREAM_DIR)" && git fetch --all --tags --quiet && git checkout --quiet "$(UPSTREAM_REF)"
	@echo "upstream is at $(UPSTREAM_REF)"

.PHONY: upstream-latest
upstream-latest: ## Repin UPSTREAM_REF to the upstream default branch HEAD
	@git ls-remote "$(UPSTREAM_REPO)" HEAD | cut -f1 > UPSTREAM_REF
	@echo "UPSTREAM_REF is now $$(cat UPSTREAM_REF)"

.PHONY: relock
relock: upstream ## Regenerate docker/backend-uv.lock from the pinned upstream pyproject
	@command -v uv >/dev/null || { echo "uv not installed: https://docs.astral.sh/uv/"; exit 1; }
	@rm -rf .relock && mkdir -p .relock
	@cp $(UPSTREAM_DIR)/backend/pyproject.toml .relock/
	@cp docker/backend-uv.lock .relock/uv.lock 2>/dev/null || true
	@cd .relock && uv lock
	@mv .relock/uv.lock docker/backend-uv.lock
	@rm -rf .relock
	@echo "docker/backend-uv.lock regenerated"

.PHONY: check-lock
check-lock: upstream ## Fail if docker/backend-uv.lock is stale for the pinned upstream
	@command -v uv >/dev/null || { echo "uv not installed"; exit 1; }
	@rm -rf .relock && mkdir -p .relock
	@cp $(UPSTREAM_DIR)/backend/pyproject.toml .relock/
	@cp docker/backend-uv.lock .relock/uv.lock
	@cd .relock && uv lock --check
	@rm -rf .relock
	@echo "docker/backend-uv.lock is current for $(UPSTREAM_REF)"

# ------------------------------------------------------------------ images --
.PHONY: images
images: build-api build-web ## Build both images locally

.PHONY: build-api
build-api: upstream ## Build the API image
	docker build -f docker/api.Dockerfile -t $(API_IMAGE) .

.PHONY: build-web
build-web: upstream ## Build the web image
	docker build -f docker/web.Dockerfile -t $(WEB_IMAGE) .

.PHONY: push
push: ## Push both images
	docker push $(API_IMAGE)
	docker push $(WEB_IMAGE)

# ------------------------------------------------------------------- chart --
.PHONY: lint
lint: ## helm lint (strict)
	helm lint $(CHART) --strict

.PHONY: template
template: ## Render the chart with default values
	helm template $(RELEASE) $(CHART)

.PHONY: validate
validate: ## Render every ci/ scenario and validate against Kubernetes schemas
	@set -euo pipefail; fail=0; \
	for f in $(CHART)/ci/*-values.yaml; do \
	  for kube in $(KUBE_VERSIONS); do \
	    printf '%-32s k8s %-8s ' "$$(basename $$f)" "$$kube"; \
	    helm template ci-test $(CHART) -f "$$f" \
	      | kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "$$kube" - \
	      || fail=1; \
	  done; \
	done; exit $$fail

.PHONY: validate-negative
validate-negative: ## Confirm the chart rejects values it cannot support
	@set -uo pipefail; \
	for args in "--set api.replicaCount=3" \
	            "--set neo4j.auth.password=short" \
	            "--set ollama.gpu.enabled=true --set ollama.gpu.count=0" \
	            "--set web.service.targetPort=80"; do \
	  if helm template bad $(CHART) $$args >/dev/null 2>&1; then \
	    echo "FAIL: expected '$$args' to be rejected"; exit 1; \
	  fi; \
	  echo "OK: rejected $$args"; \
	done

.PHONY: validate-names
validate-names: ## Confirm generated object names are unique and inside Kubernetes limits
	@python3 hack/check-names.py $(CHART)

.PHONY: validate-combos
validate-combos: ## Render scenario files together, not just one at a time
	@set -euo pipefail; \
	helm template combo $(CHART) \
	  -f $(CHART)/ci/hardened-values.yaml \
	  -f $(CHART)/ci/ingress-values.yaml \
	  -f $(CHART)/ci/gpu-values.yaml \
	  | kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.31.0 -

.PHONY: check
check: lint validate validate-negative validate-names validate-combos ## Everything CI runs for the chart

.PHONY: package
package: ## Package the chart into ./dist
	helm package $(CHART) --destination dist

# --------------------------------------------------------------- lifecycle --
.PHONY: install
install: ## Install the release (override with NAMESPACE=, RELEASE=, VALUES=)
	helm upgrade --install $(RELEASE) $(CHART) \
	  --namespace $(NAMESPACE) --create-namespace \
	  $(if $(VALUES),-f $(VALUES),) \
	  --wait --timeout 15m

.PHONY: test
test: ## Run the chart's helm tests against the installed release
	helm test $(RELEASE) --namespace $(NAMESPACE) --logs

.PHONY: uninstall
uninstall: ## Remove the release (PVCs are retained by design)
	helm uninstall $(RELEASE) --namespace $(NAMESPACE)

.PHONY: port-forward
port-forward: ## Forward the web UI to http://localhost:8080
	kubectl port-forward -n $(NAMESPACE) svc/$(RELEASE)-$(CHART_NAME)-web 8080:80

.PHONY: logs
logs: ## Tail the API logs
	kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/component=api -f --tail=200

.PHONY: clean
clean: ## Remove build scratch
	rm -rf dist rendered .relock
