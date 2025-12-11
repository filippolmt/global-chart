# Configuration
STRICT ?= --strict
GLOBAL_CHART_NAME := global-chart
RAW_CHART_NAME := raw
CHART_DIR := charts
GENERATED_DIR := generated-manifests

# Docker images
KUBE_LINTER_VERSION := $(shell if [ "$(shell uname -m)" = "x86_64" ]; then echo "latest-alpine-amd64"; else echo "latest-alpine-arm64"; fi)
KUBE_LINTER_IMAGE := ghcr.io/stackrox/kube-linter:$(KUBE_LINTER_VERSION)
HELM_DOCS_IMAGE := jnorwood/helm-docs:latest

# Test cases: values_file:namespace:slug
# Used by lint-chart, generate-templates, and kube-linter
TEST_CASES := \
	tests/test01/values.01.yaml:test:test01 \
	tests/values.02.yaml:test:test02 \
	tests/values.03.yaml:test:test03 \
	tests/mountedcm1.yaml:mountedcm1:mountedcm1 \
	tests/mountedcm2.yaml:mountedcm2:mountedcm2 \
	tests/cron-only.yaml:cron:cron \
	tests/hook-only.yaml:hooks:hooks \
	tests/externalsecret-only.yaml:externalsecrets:externalsecret \
	tests/ingress-custom.yaml:ingress:ingress \
	tests/external-ingress.yaml:ingress:external-ingress \
	tests/rbac.yaml:rbac:rbac \
	tests/multi-deployment.yaml:multi:multi-deployment \
	tests/service-disabled.yaml:svc-disabled:service-disabled \
	tests/raw-deployment.yaml:raw:raw-deployment \
	tests/deployment-hooks-cronjobs.yaml:deploy-hooks:deployment-hooks-cronjobs \
	tests/hooks-sa-inheritance.yaml:hooks-sa:hooks-sa-inheritance

# Default target
.DEFAULT_GOAL := help

# ============================================================================
# Help
# ============================================================================

.PHONY: help
help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ============================================================================
# Main targets
# ============================================================================

.PHONY: all
all: lint-chart generate-templates ## Run lint and generate templates

.PHONY: lint-chart
lint-chart: ## Lint chart with all test values files
	@echo "==> Linting chart with all test cases..."
	@set -e; for entry in $(TEST_CASES); do \
		values="$${entry%%:*}"; \
		echo "    Linting with $${values}"; \
		helm lint $(STRICT) -f "$${values}" ./$(CHART_DIR)/$(GLOBAL_CHART_NAME); \
	done
	@echo "==> All lint checks passed!"

.PHONY: generate-templates
generate-templates: lint-chart ## Generate templates for all test cases
	@echo "==> Generating templates..."
	@rm -rf $(GENERATED_DIR) || true
	@mkdir -p $(GENERATED_DIR)
	@set -e; for entry in $(TEST_CASES); do \
		values="$${entry%%:*}"; rest="$${entry#*:}"; namespace="$${rest%%:*}"; slug="$${rest##*:}"; \
		out_dir="$(GENERATED_DIR)/$${slug}"; \
		echo "    Generating $${slug}"; \
		helm template "test-$${slug}-$(GLOBAL_CHART_NAME)" "./$(CHART_DIR)/$(GLOBAL_CHART_NAME)" \
			-f "$${values}" \
			--namespace "$${namespace}" \
			--output-dir "$${out_dir}" \
			--include-crds; \
	done
	@echo "==> Templates generated in $(GENERATED_DIR)/"

# ============================================================================
# Kube-linter
# ============================================================================

.PHONY: kube-linter-manifests
kube-linter-manifests: ## Generate manifests for kube-linter
	@echo "==> Generating manifests for kube-linter..."
	@rm -rf $(GENERATED_DIR)/kube-linter || true
	@mkdir -p $(GENERATED_DIR)/kube-linter
	@set -e; for entry in $(TEST_CASES); do \
		values="$${entry%%:*}"; rest="$${entry#*:}"; namespace="$${rest%%:*}"; slug="$${rest##*:}"; \
		out_dir="$(GENERATED_DIR)/kube-linter/$${slug}"; \
		mkdir -p "$${out_dir}"; \
		helm template "lint-$${slug}-$(GLOBAL_CHART_NAME)" "./$(CHART_DIR)/$(GLOBAL_CHART_NAME)" \
			-f "$${values}" \
			--namespace "$${namespace}" \
			--output-dir "$${out_dir}" \
			--include-crds; \
	done

.PHONY: kube-linter
kube-linter: kube-linter-manifests ## Run kube-linter on generated manifests
	@echo "==> Running kube-linter..."
	@docker run --rm \
		-v $(PWD):/workspace \
		$(KUBE_LINTER_IMAGE) \
		lint "/workspace/$(GENERATED_DIR)/kube-linter" \
		--config "/workspace/.kube-linter-config.yaml"

# ============================================================================
# Documentation
# ============================================================================

.PHONY: generate-docs
generate-docs: ## Generate Helm documentation
	@echo "==> Generating Helm docs..."
	@docker run --rm --volume "$$(pwd)/$(CHART_DIR)/$(GLOBAL_CHART_NAME):/helm-docs" -u $$(id -u) $(HELM_DOCS_IMAGE) --sort-values-order file
	@docker run --rm --volume "$$(pwd)/$(CHART_DIR)/$(RAW_CHART_NAME):/helm-docs" -u $$(id -u) $(HELM_DOCS_IMAGE) --sort-values-order file
	@echo "==> Documentation generated!"

# ============================================================================
# Packaging
# ============================================================================

.PHONY: package
package: lint-chart ## Package chart for distribution
	@echo "==> Packaging chart..."
	helm package $(CHART_DIR)/$(GLOBAL_CHART_NAME)

# ============================================================================
# Install targets (for local testing)
# ============================================================================

.PHONY: install-test01
install-test01: ## Install chart with test01 values
	kubectl apply -f tests/test01/test01.yaml || true
	helm upgrade --install test ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) \
		-f tests/test01/values.01.yaml \
		--namespace test01 \
		--create-namespace

.PHONY: install-test02
install-test02: ## Install chart with test02 values
	helm upgrade --install test ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) \
		-f tests/values.02.yaml \
		--namespace test02 \
		--create-namespace

.PHONY: install-test03
install-test03: ## Install chart with test03 values
	helm upgrade --install test ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) \
		-f tests/values.03.yaml \
		--namespace test03 \
		--create-namespace

.PHONY: install-mountedcm1
install-mountedcm1: ## Install chart with mountedcm1 values
	helm upgrade --install test ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) \
		-f tests/mountedcm1.yaml \
		--namespace mountedcm1 \
		--create-namespace

.PHONY: install-mountedcm2
install-mountedcm2: ## Install chart with mountedcm2 values
	helm upgrade --install test ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) \
		-f tests/mountedcm2.yaml \
		--namespace mountedcm2 \
		--create-namespace

.PHONY: install-multi
install-multi: ## Install chart with multi-deployment values
	helm upgrade --install test ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) \
		-f tests/multi-deployment.yaml \
		--namespace multi \
		--create-namespace

# ============================================================================
# Cleanup
# ============================================================================

.PHONY: clean
clean: ## Remove generated files
	@echo "==> Cleaning generated files..."
	@rm -rf $(GENERATED_DIR)
	@rm -f *.tgz
	@echo "==> Clean complete!"

.PHONY: clean-all
clean-all: clean ## Remove all generated files and uninstall test releases
	@echo "==> Uninstalling test releases..."
	-helm uninstall test -n test01 2>/dev/null || true
	-helm uninstall test -n test02 2>/dev/null || true
	-helm uninstall test -n test03 2>/dev/null || true
	-helm uninstall test -n mountedcm1 2>/dev/null || true
	-helm uninstall test -n mountedcm2 2>/dev/null || true
	-helm uninstall test -n multi 2>/dev/null || true
	@echo "==> Clean-all complete!"
