# Configuration
STRICT ?= --strict
GLOBAL_CHART_NAME := global-chart
RAW_CHART_NAME := raw
CHART_DIR := charts
GENERATED_DIR := generated-manifests

# Docker images
KUBE_LINTER_VERSION := 0.7.1
KUBE_LINTER_IMAGE := ghcr.io/stackrox/kube-linter:v$(KUBE_LINTER_VERSION)
HELM_DOCS_IMAGE := jnorwood/helm-docs:latest
HELM_UNITTEST_IMAGE := helmunittest/helm-unittest:3.19.0-1.0.3
KUBECONFORM_VERSION := v0.7.0
KUBECONFORM_IMAGE := ghcr.io/yannh/kubeconform:$(KUBECONFORM_VERSION)

# Test cases: values_file:namespace:slug
# Used by lint-chart, generate-templates, and kube-linter
TEST_CASES := \
	tests/test01/values.01.yaml:test01:test01 \
	tests/values.02.yaml:test02:test02 \
	tests/values.03.yaml:test03:test03 \
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
	tests/deployment-hooks-cronjobs.yaml:deploy-hooks:deploy-hooks-cj \
	tests/hooks-sa-inheritance.yaml:hooks-sa:hooks-sa-inheritance \
	tests/name-collision.yaml:default:name-collision

# Default target
.DEFAULT_GOAL := help

# All phony targets
.PHONY: help all lint-chart unit-test validate-bad-values generate-templates \
	kubeconform kube-linter-manifests kube-linter generate-docs package \
	install install-test01 render clean clean-all

# ============================================================================
# Help
# ============================================================================

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make install SCENARIO=test01                                          Install a test scenario"
	@echo "  make render VALUES=tests/test01/values.01.yaml TEMPLATE=deployment.yaml   Render a single template"
	@echo ""
	@echo "Available scenarios:"
	@for entry in $(TEST_CASES); do slug="$${entry##*:}"; printf "  %s\n" "$$slug"; done

# ============================================================================
# Main targets
# ============================================================================

all: lint-chart unit-test validate-bad-values generate-templates kubeconform kube-linter ## Run lint, unit tests, bad-values, generate, validate, and lint manifests

lint-chart: ## Lint chart with all test values files
	@echo "==> Linting chart with all test cases..."
	@set -e; for entry in $(TEST_CASES); do \
		values="$${entry%%:*}"; \
		echo "    Linting with $${values}"; \
		helm lint $(STRICT) -f "$${values}" ./$(CHART_DIR)/$(GLOBAL_CHART_NAME); \
	done
	@echo "==> All lint checks passed!"

unit-test: ## Run helm-unittest via Docker
	@echo "==> Running helm unit tests..."
	@docker run --rm -u $$(id -u):$$(id -g) -v $(CURDIR)/$(CHART_DIR)/$(GLOBAL_CHART_NAME):/apps -w /apps $(HELM_UNITTEST_IMAGE) .
	@echo "==> All unit tests passed!"

validate-bad-values: ## Verify that bad-values files are rejected by schema validation
	@echo "==> Validating bad-values are correctly rejected..."
	@set -e; for f in tests/bad-values/*.yaml; do \
		if helm lint $(STRICT) -f "$$f" ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) >/dev/null 2>&1; then \
			echo "    FAIL: $$f should have been rejected but was accepted"; \
			exit 1; \
		else \
			echo "    OK: $$f correctly rejected"; \
		fi; \
	done
	@echo "==> All bad-values correctly rejected!"

# Internal: generate templates to a given directory
define _helm_generate
	@set -e; for entry in $(TEST_CASES); do \
		values="$${entry%%:*}"; rest="$${entry#*:}"; namespace="$${rest%%:*}"; slug="$${rest##*:}"; \
		out_dir="$(1)/$${slug}"; \
		echo "    Generating $${slug}"; \
		mkdir -p "$${out_dir}"; \
		helm template "test-$${slug}-$(GLOBAL_CHART_NAME)" "./$(CHART_DIR)/$(GLOBAL_CHART_NAME)" \
			-f "$${values}" \
			--namespace "$${namespace}" \
			--output-dir "$${out_dir}" \
			--include-crds; \
	done
endef

generate-templates: lint-chart ## Generate templates for all test cases
	@echo "==> Generating templates..."
	@rm -rf $(GENERATED_DIR) || true
	@mkdir -p $(GENERATED_DIR)
	$(call _helm_generate,$(GENERATED_DIR))
	@echo "==> Templates generated in $(GENERATED_DIR)/"

# ============================================================================
# Kubeconform
# ============================================================================

kubeconform: generate-templates ## Validate generated manifests against K8s 1.29 schema
	@echo "==> Running kubeconform..."
	@docker run --rm \
		-v $(CURDIR):/work \
		$(KUBECONFORM_IMAGE) \
		-kubernetes-version 1.29.0 \
		-strict \
		-summary \
		-schema-location default \
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/external-secrets.io/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
		-output pretty \
		/work/$(GENERATED_DIR)
	@echo "==> Kubeconform validation passed!"

# ============================================================================
# Kube-linter
# ============================================================================

kube-linter-manifests: ## Generate manifests for kube-linter
	@echo "==> Generating manifests for kube-linter..."
	@rm -rf $(GENERATED_DIR)/kube-linter || true
	$(call _helm_generate,$(GENERATED_DIR)/kube-linter)

kube-linter: kube-linter-manifests ## Run kube-linter on generated manifests
	@echo "==> Running kube-linter..."
	@docker run --rm \
		-v $(CURDIR):/workspace \
		$(KUBE_LINTER_IMAGE) \
		lint "/workspace/$(GENERATED_DIR)/kube-linter" \
		--config "/workspace/.kube-linter-config.yaml"

# ============================================================================
# Documentation
# ============================================================================

generate-docs: ## Generate Helm documentation
	@echo "==> Generating Helm docs..."
	@docker run --rm --volume "$(CURDIR)/$(CHART_DIR)/$(GLOBAL_CHART_NAME):/helm-docs" -u $$(id -u) $(HELM_DOCS_IMAGE) --sort-values-order file
	@docker run --rm --volume "$(CURDIR)/$(CHART_DIR)/$(RAW_CHART_NAME):/helm-docs" -u $$(id -u) $(HELM_DOCS_IMAGE) --sort-values-order file
	@echo "==> Documentation generated!"

# ============================================================================
# Packaging
# ============================================================================

package: lint-chart ## Package chart for distribution
	@echo "==> Packaging chart..."
	helm package $(CHART_DIR)/$(GLOBAL_CHART_NAME)

# ============================================================================
# Install targets (for local testing)
# ============================================================================

install: ## Install a test scenario (usage: make install SCENARIO=test01)
	@if [ -z "$(SCENARIO)" ]; then \
		echo "Usage: make install SCENARIO=<slug>"; \
		echo "Available scenarios:"; \
		for entry in $(TEST_CASES); do \
			slug="$${entry##*:}"; \
			echo "  $$slug"; \
		done; \
		exit 1; \
	fi
	@found=0; for entry in $(TEST_CASES); do \
		values="$${entry%%:*}"; rest="$${entry#*:}"; namespace="$${rest%%:*}"; slug="$${rest##*:}"; \
		if [ "$$slug" = "$(SCENARIO)" ]; then \
			found=1; \
			echo "==> Installing $$slug (namespace: $$namespace)..."; \
			helm upgrade --install test ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) \
				-f "$$values" \
				--namespace "$$namespace" \
				--create-namespace; \
			break; \
		fi; \
	done; \
	if [ $$found -eq 0 ]; then \
		echo "Error: scenario '$(SCENARIO)' not found"; exit 1; \
	fi

install-test01: ## Install test01 (has kubectl pre-step; or use: make install SCENARIO=test01)
	kubectl apply -f tests/test01/test01.yaml || true
	helm upgrade --install test ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) \
		-f tests/test01/values.01.yaml \
		--namespace test01 \
		--create-namespace

# ============================================================================
# Render (single template debugging)
# ============================================================================

render: ## Render a single template (usage: make render VALUES=<file> TEMPLATE=<name>)
	@if [ -z "$(VALUES)" ] || [ -z "$(TEMPLATE)" ]; then \
		echo "Usage: make render VALUES=<values-file> TEMPLATE=<template-name>"; \
		echo "Example: make render VALUES=tests/test01/values.01.yaml TEMPLATE=deployment.yaml"; \
		exit 1; \
	fi
	helm template test-release ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) \
		-f $(VALUES) \
		-s templates/$(TEMPLATE)

# ============================================================================
# Cleanup
# ============================================================================

clean: ## Remove generated files
	@echo "==> Cleaning generated files..."
	@rm -rf $(GENERATED_DIR)
	@rm -f *.tgz
	@echo "==> Clean complete!"

clean-all: clean ## Remove all generated files and uninstall test releases
	@echo "==> Uninstalling test releases..."
	@for entry in $(TEST_CASES); do \
		rest="$${entry#*:}"; namespace="$${rest%%:*}"; \
		helm uninstall test -n "$$namespace" 2>/dev/null || true; \
	done
	@echo "==> Clean-all complete!"
