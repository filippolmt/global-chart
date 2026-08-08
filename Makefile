# Configuration
STRICT ?= --strict
GLOBAL_CHART_NAME := global-chart
RAW_CHART_NAME := raw
CHART_DIR := charts
GENERATED_DIR := generated-manifests

# CRD API versions the chart renders but that no cluster provides offline.
# .Capabilities.APIVersions is populated from the cluster only during
# install/upgrade, so `helm template` needs these declared explicitly or the
# CRD presence check in _keda-helpers.tpl fails. (`helm lint` does not evaluate
# template `fail` and has no equivalent flag, so lint-chart needs nothing.)
HELM_API_VERSIONS := --api-versions keda.sh/v1alpha1

# Docker images
KUBE_LINTER_VERSION := 0.7.1
KUBE_LINTER_IMAGE := ghcr.io/stackrox/kube-linter:v$(KUBE_LINTER_VERSION)
HELM_DOCS_IMAGE := jnorwood/helm-docs:latest
HELM_UNITTEST_IMAGE := helmunittest/helm-unittest:3.19.0-1.0.3
KUBECONFORM_VERSION := v0.7.0
KUBECONFORM_IMAGE := ghcr.io/yannh/kubeconform:$(KUBECONFORM_VERSION)

# kind (end-to-end install tests)
# KIND_KUBECONFIG is deliberately NOT ~/.kube/config: e2e must never be able to
# touch a real cluster, whatever kubectl context happens to be selected.
KIND_VERSION := v0.30.0
KIND_CLUSTER := global-chart-e2e
KIND_BIN_DIR := $(CURDIR)/.bin
KIND := $(KIND_BIN_DIR)/kind
KIND_KUBECONFIG := $(CURDIR)/.bin/kind-kubeconfig
# KEDA operator + CRDs, so the e2e exercises the whole chain: trigger fires →
# KEDA reconciles → derived HPA → Deployment scales. The kedacore chart version
# tracks the operator version.
# HELM_REPOSITORY_* are pinned into .bin/ for the same reason KIND_KUBECONFIG is:
# a make target must not write to the developer's helm configuration.
# renovate: datasource=helm depName=keda registryUrl=https://kedacore.github.io/charts
KEDA_VERSION := 2.20.2
KEDA_REPO_URL := https://kedacore.github.io/charts
KEDA_NAMESPACE := keda
KEDA_HELM_ENV := HELM_REPOSITORY_CONFIG=$(KIND_BIN_DIR)/helm-repositories.yaml \
	HELM_REPOSITORY_CACHE=$(KIND_BIN_DIR)/helm-repo-cache
E2E_VALUES := tests/e2e/values.yaml
E2E_RELEASE := e2e
E2E_NAMESPACE := global-chart-e2e

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
	tests/service-extra-ports.yaml:svc-extra-ports:service-extra-ports \
	tests/raw-deployment.yaml:raw:raw-deployment \
	tests/deployment-hooks-cronjobs.yaml:deploy-hooks:deploy-hooks-cj \
	tests/hooks-sa-inheritance.yaml:hooks-sa:hooks-sa-inheritance \
	tests/name-collision.yaml:default:name-collision \
	tests/httproute-basic.yaml:httproute-basic:httproute-basic \
	tests/httproute-canary.yaml:httproute-canary:httproute-canary \
	tests/httproute-filters.yaml:httproute-filters:httproute-filters \
	tests/keda.yaml:keda:keda

# Default target
.DEFAULT_GOAL := help

# All phony targets
.PHONY: help all lint-chart unit-test validate-bad-values generate-templates \
	kubeconform kube-linter-manifests kube-linter generate-docs package \
	install install-test01 render clean clean-all \
	kind-install kind-cluster kind-keda kind-delete e2e

# ============================================================================
# Help
# ============================================================================

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
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

validate-bad-values: ## Verify that bad-values files are rejected by schema or template fail
	@echo "==> Validating bad-values are correctly rejected..."
	@set -e; for f in tests/bad-values/*.yaml; do \
		if helm lint $(STRICT) -f "$$f" ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) >/dev/null 2>&1 \
		&& helm template global-chart-bad-values ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) -f "$$f" >/dev/null 2>&1; then \
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
			$(HELM_API_VERSIONS) \
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
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/gateway.networking.k8s.io/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/keda.sh/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
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

# ============================================================================
# End-to-end install tests (throwaway kind cluster)
# ============================================================================

kind-install: ## Download the kind binary into .bin/ (no-op if already there)
	@if [ ! -x "$(KIND)" ]; then \
		mkdir -p $(KIND_BIN_DIR); \
		os=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
		arch=$$(uname -m); \
		case "$$arch" in aarch64|arm64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; \
			*) echo "Unsupported architecture: $$arch"; exit 1 ;; esac; \
		echo "==> Downloading kind $(KIND_VERSION) ($$os/$$arch)..."; \
		curl -sfLo "$(KIND)" "https://kind.sigs.k8s.io/dl/$(KIND_VERSION)/kind-$$os-$$arch"; \
		chmod +x "$(KIND)"; \
	fi
	@$(KIND) version

kind-cluster: kind-install ## Create the e2e kind cluster (isolated kubeconfig, never ~/.kube/config)
	@if ! $(KIND) get clusters 2>/dev/null | grep -qx "$(KIND_CLUSTER)"; then \
		echo "==> Creating kind cluster $(KIND_CLUSTER)..."; \
		$(KIND) create cluster --name "$(KIND_CLUSTER)" --kubeconfig "$(KIND_KUBECONFIG)"; \
	fi
	@# When make runs inside a container the kubeconfig's 127.0.0.1 endpoint is the
	@# Docker *host*, not us: fall back to the control-plane container's own address.
	@if ! KUBECONFIG=$(KIND_KUBECONFIG) kubectl get nodes >/dev/null 2>&1; then \
		ip=$$(docker inspect "$(KIND_CLUSTER)-control-plane" -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'); \
		echo "==> Repointing kubeconfig at the control-plane container ($$ip)..."; \
		KUBECONFIG=$(KIND_KUBECONFIG) kubectl config set-cluster "kind-$(KIND_CLUSTER)" --server="https://$$ip:6443" >/dev/null; \
	fi
	@KUBECONFIG=$(KIND_KUBECONFIG) kubectl wait --for=condition=Ready node --all --timeout=180s

kind-keda: kind-cluster ## Install KEDA (operator + CRDs) into the e2e kind cluster
	@echo "==> Installing KEDA $(KEDA_VERSION)..."
	@mkdir -p $(KIND_BIN_DIR)
	@$(KEDA_HELM_ENV) helm repo add kedacore $(KEDA_REPO_URL) --force-update >/dev/null
	@KUBECONFIG=$(KIND_KUBECONFIG) $(KEDA_HELM_ENV) helm upgrade --install keda kedacore/keda \
		--version $(KEDA_VERSION) \
		--namespace $(KEDA_NAMESPACE) --create-namespace \
		--wait --timeout 300s >/dev/null
	@KUBECONFIG=$(KIND_KUBECONFIG) kubectl wait --for=condition=Established \
		crd/scaledobjects.keda.sh crd/triggerauthentications.keda.sh --timeout=60s >/dev/null
	@echo "    KEDA operator ready"

kind-delete: ## Delete the e2e kind cluster
	@if [ -x "$(KIND)" ]; then $(KIND) delete cluster --name "$(KIND_CLUSTER)"; fi
	@rm -f "$(KIND_KUBECONFIG)"

e2e: kind-cluster kind-keda ## Install/upgrade/uninstall tests/e2e/values.yaml on kind and assert the hook lifecycle
	@set -e; \
	export KUBECONFIG=$(KIND_KUBECONFIG); \
	ns=$(E2E_NAMESPACE); rel=$(E2E_RELEASE); \
	trap 'helm uninstall $$rel -n $$ns >/dev/null 2>&1 || true; kubectl delete ns $$ns --wait=false >/dev/null 2>&1 || true' EXIT; \
	echo "==> Clearing any namespace left by a previous run..."; \
	kubectl delete ns $$ns --ignore-not-found --timeout=180s >/dev/null 2>&1 || true; \
	echo "==> Installing $$rel from $(E2E_VALUES)..."; \
	helm install $$rel ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) -f $(E2E_VALUES) \
		--namespace $$ns --create-namespace --timeout 180s >/dev/null; \
	[ "$$(helm status $$rel -n $$ns -o json | grep -o '"status":"[^"]*"' | head -1)" = '"status":"deployed"' ] \
		|| { echo "FAIL: release is not deployed"; exit 1; }; \
	echo "    release deployed"; \
	kubectl -n $$ns get job -o name | grep -q pre-install \
		|| { echo "FAIL: pre-install hook Job missing"; exit 1; }; \
	for hook in migration early; do \
		[ "$$(kubectl -n $$ns get job $$rel-$(GLOBAL_CHART_NAME)-app-pre-install-$$hook -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ] \
			|| { echo "FAIL: pre-install hook Job '$$hook' did not succeed (issue #71 regression)"; exit 1; }; \
	done; \
	echo "    both pre-install hooks ran under the chart-created ServiceAccount"; \
	echo "    the negative-weight hook found its prerequisite ConfigMap (weight invariant holds)"; \
	kubectl -n $$ns get sa $$rel-$(GLOBAL_CHART_NAME)-app -o jsonpath='{.metadata.annotations}' | grep -q 'helm.sh/hook' \
		&& { echo "FAIL: the surviving SA is the hook copy, not the real one"; exit 1; } || true; \
	echo "    hook-prerequisite SA copy cleaned up, real SA in place"; \
	[ "$$(kubectl -n $$ns get deploy $$rel-$(GLOBAL_CHART_NAME)-app -o jsonpath='{.spec.template.spec.containers[0].command}')" = '["sh","-c"]' ] \
		|| { echo "FAIL: deployment command not rendered (issue #72 regression)"; exit 1; }; \
	echo "    deployment command/args rendered"; \
	echo "==> Waiting for Service endpoints..."; \
	for d in app web; do \
		kubectl -n $$ns rollout status deploy/$$rel-$(GLOBAL_CHART_NAME)-$$d --timeout=180s >/dev/null \
			|| { echo "FAIL: deployment '$$d' never became available"; exit 1; }; \
		kubectl -n $$ns wait --for=jsonpath='{.endpoints[0].conditions.ready}'=true \
			endpointslice -l kubernetes.io/service-name=$$rel-$(GLOBAL_CHART_NAME)-$$d --timeout=120s >/dev/null \
			|| { echo "FAIL: Service '$$d' never got a ready endpoint"; exit 1; }; \
	done; \
	for expected in app:admin=8081 web:api=8080 web:metrics=9090 web:metrics-alias=9090; do \
		d=$${expected%%:*}; pair=$${expected#*:}; \
		kubectl -n $$ns get endpointslice -l kubernetes.io/service-name=$$rel-$(GLOBAL_CHART_NAME)-$$d \
			-o jsonpath='{range .items[*].ports[*]}{.name}={.port}{"\n"}{end}' | grep -qx "$$pair" \
			|| { echo "FAIL: Service '$$d' port '$${pair%%=*}' resolved to no endpoint port $${pair#*=} (issue #82 regression)"; \
			     kubectl -n $$ns get endpointslice -l kubernetes.io/service-name=$$rel-$(GLOBAL_CHART_NAME)-$$d -o yaml; exit 1; }; \
	done; \
	echo "    every Service targetPort resolved to a container port and got endpoints"; \
	[ "$$(kubectl -n $$ns get scaledobject $$rel-$(GLOBAL_CHART_NAME)-worker -o jsonpath='{.spec.maxReplicaCount}')" = "10" ] \
		|| { echo "FAIL: ScaledObject missing or maxReplicaCount not rendered"; exit 1; }; \
	[ "$$(kubectl -n $$ns get scaledobject $$rel-$(GLOBAL_CHART_NAME)-worker -o jsonpath='{.spec.scaleTargetRef.name}')" = "$$rel-$(GLOBAL_CHART_NAME)-worker" ] \
		|| { echo "FAIL: ScaledObject scaleTargetRef does not point at its Deployment"; exit 1; }; \
	[ "$$(kubectl -n $$ns get scaledobject $$rel-$(GLOBAL_CHART_NAME)-worker -o jsonpath='{.spec.triggers[0].authenticationRef.name}')" = "$$rel-$(GLOBAL_CHART_NAME)-e2e-auth" ] \
		|| { echo "FAIL: authenticationRef was not resolved to the chart-rendered TriggerAuthentication name"; exit 1; }; \
	kubectl -n $$ns get triggerauthentication $$rel-$(GLOBAL_CHART_NAME)-e2e-auth >/dev/null 2>&1 \
		|| { echo "FAIL: TriggerAuthentication missing"; exit 1; }; \
	echo "    ScaledObject and TriggerAuthentication applied, authenticationRef resolved"; \
	kubectl -n $$ns wait --for=condition=Ready scaledobject/$$rel-$(GLOBAL_CHART_NAME)-worker --timeout=180s >/dev/null \
		|| { echo "FAIL: KEDA never marked the ScaledObject Ready"; \
		     kubectl -n $$ns get scaledobject $$rel-$(GLOBAL_CHART_NAME)-worker -o jsonpath='{.status.conditions}'; exit 1; }; \
	echo "    ScaledObject accepted by the KEDA operator"; \
	[ "$$(kubectl -n $$ns get hpa keda-hpa-$$rel-$(GLOBAL_CHART_NAME)-worker -o jsonpath='{.spec.maxReplicas}')" = "10" ] \
		|| { echo "FAIL: derived HPA missing or maxReplicaCount did not reach it"; exit 1; }; \
	[ "$$(kubectl -n $$ns get hpa keda-hpa-$$rel-$(GLOBAL_CHART_NAME)-worker -o jsonpath='{.spec.scaleTargetRef.name}')" = "$$rel-$(GLOBAL_CHART_NAME)-worker" ] \
		|| { echo "FAIL: derived HPA does not target the chart's Deployment"; exit 1; }; \
	echo "    KEDA created the derived HPA with the rendered bounds"; \
	kubectl -n $$ns wait --for=jsonpath='{.spec.replicas}'=3 deployment/$$rel-$(GLOBAL_CHART_NAME)-worker --timeout=180s >/dev/null \
		|| { echo "FAIL: the cron trigger never scaled the Deployment to desiredReplicas"; \
		     kubectl -n $$ns get deployment $$rel-$(GLOBAL_CHART_NAME)-worker hpa -o wide; exit 1; }; \
	echo "    cron trigger scaled the Deployment to 3 through the full KEDA chain"; \
	echo "==> Upgrading (exercises the pre-upgrade hook)..."; \
	sa_before=$$(kubectl -n $$ns get sa $$rel-$(GLOBAL_CHART_NAME)-app -o jsonpath='{.metadata.uid}'); \
	helm upgrade $$rel ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) -f $(E2E_VALUES) \
		--namespace $$ns --timeout 180s >/dev/null; \
	[ "$$sa_before" = "$$(kubectl -n $$ns get sa $$rel-$(GLOBAL_CHART_NAME)-app -o jsonpath='{.metadata.uid}')" ] \
		|| { echo "FAIL: the ServiceAccount was recreated, bound tokens would be invalidated"; exit 1; }; \
	echo "    upgrade kept the ServiceAccount identity"; \
	{ [ "$$(kubectl -n $$ns get deployment $$rel-$(GLOBAL_CHART_NAME)-worker -o jsonpath='{.spec.replicas}')" = "3" ] \
		|| { echo "FAIL: upgrade reset spec.replicas on a KEDA-scaled Deployment"; exit 1; }; }; \
	echo "    upgrade left spec.replicas to the autoscaler"; \
	echo "==> Uninstalling and checking for orphaned hook resources..."; \
	helm uninstall $$rel -n $$ns >/dev/null; \
	orphans=$$(kubectl -n $$ns get sa,cm,secret --no-headers 2>/dev/null \
		| grep -v 'serviceaccount/default\|kube-root-ca.crt' || true); \
	if [ -n "$$orphans" ]; then echo "FAIL: hook resources orphaned after uninstall:"; echo "$$orphans"; exit 1; fi; \
	echo "    no orphaned ConfigMap/Secret/ServiceAccount"; \
	keda_orphans=$$(kubectl -n $$ns get scaledobject,triggerauthentication,hpa --no-headers 2>/dev/null || true); \
	if [ -n "$$keda_orphans" ]; then echo "FAIL: KEDA resources orphaned after uninstall:"; echo "$$keda_orphans"; exit 1; fi; \
	echo "    no orphaned ScaledObject/TriggerAuthentication, derived HPA garbage-collected"; \
	echo "==> e2e passed"

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
		$(HELM_API_VERSIONS) \
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
