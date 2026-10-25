# Configuration
STRICT ?= --strict

# What Helm prints when values.schema.json rejects a file. A message, not a
# contract: validate-bad-values asserts it so that a file in bad-values/schema/
# proves the *schema* caught the typo, not some template fail further down.
SCHEMA_REJECTION := values don't meet the specifications of the schema
GLOBAL_CHART_NAME := global-chart
RAW_CHART_NAME := raw
CHART_DIR := charts
GENERATED_DIR := generated-manifests

# CRD API versions the chart renders but that no cluster provides offline.
# .Capabilities.APIVersions is populated from the cluster only during
# install/upgrade, so `helm template` needs these declared explicitly or the
# CRD presence check (requireCrd, _validate-helpers.tpl) fails. (`helm lint` does not evaluate
# template `fail` and has no equivalent flag, so lint-chart needs nothing.)
HELM_API_VERSIONS := --api-versions keda.sh/v1alpha1 \
	--api-versions gateway.networking.k8s.io/v1/HTTPRoute \
	--api-versions gateway.networking.k8s.io/v1/TCPRoute \
	--api-versions gateway.networking.k8s.io/v1/UDPRoute \
	--api-versions gateway.envoyproxy.io/v1alpha1/SecurityPolicy

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
KEDA_VERSION := 2.21.0
KEDA_REPO_URL := https://kedacore.github.io/charts
KEDA_NAMESPACE := keda
HELM_REPO_ENV := HELM_REPOSITORY_CONFIG=$(KIND_BIN_DIR)/helm-repositories.yaml \
	HELM_REPOSITORY_CACHE=$(KIND_BIN_DIR)/helm-repo-cache
# External Secrets Operator + CRDs, so a hook reading an ExternalSecret's Secret
# is exercised for real (issue #110, ADR 0007): the store is ESO's fake provider.
# renovate: datasource=helm depName=external-secrets registryUrl=https://charts.external-secrets.io
ESO_VERSION := 2.14.0
ESO_REPO_URL := https://charts.external-secrets.io
ESO_NAMESPACE := external-secrets
# Gateway API CRDs (standard channel, no controller), so the routes the chart
# renders are validated by a real API server against the real CRD schema: kubeconform
# reads a third-party copy of it, and TCPRoute/UDPRoute reach v1 only in v1.6.0
# (issue #194). Nothing routes traffic: there is no Gateway controller.
# renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api
GATEWAY_API_VERSION := v1.6.3
# SecurityPolicy CRD only, no Envoy Gateway controller: validate the opt-in
# policy against its upstream schema without claiming authentication works.
# renovate: datasource=github-releases depName=envoyproxy/gateway
ENVOY_GATEWAY_VERSION := v1.7.2
# The Gateway API kinds the chart renders: httproute.yaml and l4RouteKinds
# (_render-helpers.tpl) are their source, mirrored here; change both.
# kind-gateway-api waits for their CRDs, and e2e-dryrun asserts that some
# TEST_CASES scenario renders one of them.
GATEWAY_ROUTE_KINDS := HTTPRoute TCPRoute UDPRoute
GATEWAY_ROUTE_CRDS := $(foreach k,$(GATEWAY_ROUTE_KINDS),crd/$(shell echo $(k) | tr A-Z a-z)s.gateway.networking.k8s.io)
GATEWAY_ROUTE_KIND_RE := ^kind: ($(subst $(subst ,, ),|,$(GATEWAY_ROUTE_KINDS)))$$
# Argo CD core (no UI, no dex), for `make e2e-argocd`: the hook-prerequisite
# copies under a real sync, where pre-install runs on every sync and a failed
# operation marks every hook HookFailed (issues #149, #164).
# renovate: datasource=github-releases depName=argoproj/argo-cd
ARGOCD_VERSION := v3.5.6
ARGOCD_NAMESPACE := argocd
# Helm just below the floor the job schema closures need (issue #116): the
# NOTES.txt warning must show on it. helm-unittest runs its own newer Helm and
# cannot fake .Capabilities.HelmVersion, so only this target sees the warning.
HELM_FLOOR_IMAGE := alpine/helm:3.18.5
HELM_FLOOR_KUBECONFIG := $(KIND_BIN_DIR)/floor-kubeconfig
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
	tests/externalsecret-hooks.yaml:externalsecret-hooks:externalsecret-hooks \
	tests/ingress-custom.yaml:ingress:ingress \
	tests/external-ingress.yaml:ingress:external-ingress \
	tests/rbac.yaml:rbac:rbac \
	tests/rbac-hooks.yaml:rbac-hooks:rbac-hooks \
	tests/multi-workload.yaml:multi:multi-workload \
	tests/service-disabled.yaml:svc-disabled:service-disabled \
	tests/service-extra-ports.yaml:svc-extra-ports:service-extra-ports \
	tests/raw-workload.yaml:raw:raw-workload \
	tests/workload-hooks-cronjobs.yaml:deploy-hooks:workload-hooks-cj \
	tests/hooks-sa-inheritance.yaml:hooks-sa:hooks-sa-inheritance \
	tests/name-collision.yaml:default:name-collision \
	tests/httproute-basic.yaml:httproute-basic:httproute-basic \
	tests/httproute-basic-auth.yaml:httproute-basic-auth:httproute-basic-auth \
	tests/httproute-canary.yaml:httproute-canary:httproute-canary \
	tests/httproute-filters.yaml:httproute-filters:httproute-filters \
	tests/l4routes.yaml:l4routes:l4routes \
	tests/httproutes.yaml:httproutes:httproutes \
	tests/keda.yaml:keda:keda \
	tests/common-annotations.yaml:common-annotations:common-annotations \
	tests/statefulset.yaml:statefulset:statefulset \
	docs/values-authors/examples/web.yaml:example-web:example-web \
	docs/values-authors/examples/worker.yaml:example-worker:example-worker \
	docs/values-authors/examples/cronjob.yaml:example-cronjob:example-cronjob \
	docs/values-authors/examples/migration-hook.yaml:example-migration-hook:example-migration-hook \
	docs/values-authors/examples/externalsecret.yaml:example-externalsecret:example-externalsecret

# Default target
.DEFAULT_GOAL := help

# All phony targets
.PHONY: help scenarios all check lint-chart render-diff lint-templates lint-docs lint-shell lint-glossary lint-inheritance lint-checks lint-labels unit-test null-sweep scenario-coverage schema-descriptions schema-bounds lint-release release validate-bad-values generate-templates \
	kubeconform kube-linter-manifests kube-linter generate-docs package \
	install install-test01 render clean clean-all \
	kind-install kind-cluster kind-keda kind-eso kind-gateway-api kind-envoy-gateway kind-argocd kind-delete e2e e2e-dryrun bound-sweep e2e-routes e2e-argocd check-helm-floor

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
	@echo "  make render VALUES=tests/test01/values.01.yaml TEMPLATE=workload.yaml   Render a single template"
	@echo ""
	@echo "Available scenarios:"
	@for entry in $(TEST_CASES); do slug="$${entry##*:}"; printf "  %s\n" "$$slug"; done

scenarios: ## Print the values file of every TEST_CASES scenario, one per line, for a check script run by hand: $(make -s scenarios)
	@for entry in $(TEST_CASES); do printf '%s\n' "$${entry%%:*}"; done

# ============================================================================
# Main targets
# ============================================================================

all: check null-sweep generate-templates kubeconform kube-linter ## make check, the null sweep, then generate, validate and lint the manifests
	@echo "==> make all: every check passed"

check: lint-chart lint-templates lint-docs lint-shell lint-glossary lint-inheritance lint-checks unit-test validate-bad-values scenario-coverage schema-descriptions schema-bounds lint-release ## The development loop: every fast check, its prerequisites listed here (no null sweep, no manifest validation: make all and CI run them)

lint-chart: ## Lint chart with all test values files
	@echo "==> Linting chart with all test cases..."
	@# helm lint logs a template fail at INFO and passes: the one fail a valid
	@# scenario may hit offline is the CRD check, any other is a finding.
	@set -e; for entry in $(TEST_CASES); do \
		values="$${entry%%:*}"; \
		if ! out=$$(helm lint $(STRICT) -f "$${values}" ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) 2>&1); then \
			echo "    FAIL: $${values}"; printf '%s\n' "$$out"; exit 1; \
		fi; \
		other=$$(printf '%s\n' "$$out" | grep 'funcMap fail' | grep -v 'needs the CRD' || true); \
		if [ -n "$$other" ]; then \
			echo "    FAIL: $${values} hits a template fail other than the CRD check:"; printf '%s\n' "$$other"; exit 1; \
		fi; \
		echo "    OK: $${values}"; \
	done
	@echo "==> All lint checks passed!"

lint-templates: ## Check the mechanical rules of CODING_STANDARDS.md on the templates
	@echo "==> Checking template coding rules..."
	@python3 tests/lint-templates.py ./$(CHART_DIR)/$(GLOBAL_CHART_NAME)

lint-docs: ## Check that every file a document or a comment points at exists
	@echo "==> Checking documentation pointers..."
	@python3 tests/lint-docs.py

lint-shell: ## A value piped onward in the Makefile or a script goes through printf, not echo
	@echo "==> Checking shell pipes..."
	@python3 tests/lint-shell.py

lint-glossary: ## The phrases GLOSSARY.md avoids with one reading only stay out of the tracked files
	@echo "==> Checking glossary terms..."
	@python3 tests/lint-glossary.py

lint-checks: ## Every make all target has a CI step; every check script fails with a FAIL line, not a traceback, on a missing input
	@echo "==> Checking the check scripts..."
	@python3 tests/lint-checks.py --self-test
	@python3 tests/tools/schema-describe.py --self-test
	@python3 .claude/hooks/kind-kubeconfig-only.py --self-test
	@python3 tests/render-diff.py --self-test
	@python3 tests/lint-checks.py

lint-inheritance: ## The schema and the values-author guide state the inheritance the jobPodSpec header lists
	@echo "==> Checking the inheritance rules..."
	@python3 tests/check-inheritance.py --self-test ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) docs/values-authors/README.md
	@python3 tests/check-inheritance.py ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) docs/values-authors/README.md

null-sweep: ## Null every values node of every scenario in turn, then give each map and list the wrong type: each must render or fail naming its path
	@echo "==> Sweeping nulls and wrong types under --skip-schema-validation..."
	@python3 tests/bad-values/null-sweep.py ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) \
		$(foreach e,$(TEST_CASES),$(firstword $(subst :, ,$(e)))) -- $(HELM_API_VERSIONS)

scenario-coverage: ## Every map or list node of the schema is set by a scenario, every type a node accepts used by one (new gaps fail; the baseline only shrinks)
	@echo "==> Checking the scenarios cover the schema..."
	@python3 tests/check-scenario-coverage.py ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) tests/scenario-coverage-baseline.txt \
		$(foreach e,$(TEST_CASES),$(firstword $(subst :, ,$(e))))

schema-descriptions: ## Every schema property carries a description
	@echo "==> Checking the schema descriptions..."
	@python3 tests/check-schema-descriptions.py --self-test
	@python3 tests/check-schema-descriptions.py ./$(CHART_DIR)/$(GLOBAL_CHART_NAME)/values.schema.json

schema-bounds: ## Every schema integer has a maximum within 2^53-1, every digit-string pattern a digit count
	@echo "==> Checking the schema's integer bounds..."
	@python3 tests/check-schema-bounds.py --self-test
	@python3 tests/check-schema-bounds.py ./$(CHART_DIR)/$(GLOBAL_CHART_NAME)/values.schema.json

lint-release: ## Chart.yaml's version is the CHANGELOG's last release, or the release its top section names
	@echo "==> Checking Chart.yaml against the CHANGELOG..."
	@python3 tests/check-release.py --self-test
	@python3 tests/check-release.py CHANGELOG.md ./$(CHART_DIR)/$(GLOBAL_CHART_NAME)/Chart.yaml

release: ## The release PR's edit: VERSION=x.y.z renames [Unreleased], bumps Chart.yaml, regenerates the README; refuses a non-major over a Removed section
	@[ -n "$(VERSION)" ] || { echo "    FAIL: VERSION: not set; make release VERSION=x.y.z"; exit 1; }
	@python3 tests/check-release.py --bump $(VERSION) CHANGELOG.md ./$(CHART_DIR)/$(GLOBAL_CHART_NAME)/Chart.yaml
	@$(MAKE) --no-print-directory generate-docs

lint-labels: ## Every triage label docs/agents/triage-labels.md names exists on GitHub (needs gh; not in check, which stays offline)
	@echo "==> Checking triage labels..."
	@python3 tests/lint-labels.py

unit-test: ## Run helm-unittest via Docker and verify random Basic Auth credentials; SUITE=tests/<name>_test.yaml (space-separated, relative to the chart) runs only those suites
	@echo "==> Running helm unit tests..."
	@# helm-unittest runs 0 suites and passes on a SUITE path that names no file
	@for f in $(SUITE); do [ -f "$(CHART_DIR)/$(GLOBAL_CHART_NAME)/$$f" ] || { echo "    FAIL: SUITE=$$f names no file under $(CHART_DIR)/$(GLOBAL_CHART_NAME)/ (the path is relative to the chart: tests/<name>_test.yaml)"; exit 1; }; done
	@docker run --rm -u $$(id -u):$$(id -g) -v $(CURDIR)/$(CHART_DIR)/$(GLOBAL_CHART_NAME):/apps -w /apps $(HELM_UNITTEST_IMAGE) $(foreach f,$(SUITE),-f $(f)) .
	@python3 tests/check-basic-auth.py $(HELM_API_VERSIONS)
	@echo "==> All unit tests passed!"

render-diff: ## Render every TEST_CASES scenario on BASE (default main) and on the working tree, and diff them; BASE=<ref> picks the base, QUOTES=ignore reads "x" as x where x stays a string
	@echo "==> Diffing the rendered manifests against $(or $(BASE),main)..."
	@python3 tests/render-diff.py $(if $(filter ignore,$(QUOTES)),--ignore-quotes) $(or $(BASE),main) $(HELM_API_VERSIONS)

validate-bad-values: ## Verify bad-values are rejected: schema/ by values.schema.json, fail/ by the template fail each names, skip-schema/ by both (the fail under --skip-schema-validation)
	@echo "==> Validating bad-values are correctly rejected..."
	@set -e; for f in tests/bad-values/schema/*.yaml; do \
		[ -e "$$f" ] || { echo "    FAIL: tests/bad-values/schema/ holds no fixture; green here would be vacuous"; exit 1; }; \
		if ! helm lint $(STRICT) -f "$$f" ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) 2>&1 | grep -qF "$(SCHEMA_REJECTION)"; then \
			echo "    FAIL: $$f was not rejected by values.schema.json"; \
			echo "          (if every file here fails, check whether Helm reworded: $(SCHEMA_REJECTION))"; \
			exit 1; \
		fi; \
	done
	@set -e; for f in tests/bad-values/fail/*.yaml; do \
		[ -e "$$f" ] || { echo "    FAIL: tests/bad-values/fail/ holds no fixture; green here would be vacuous"; exit 1; }; \
		subs=$$(sed -n 's/^# Expected fail substring: "\(.*\)"$$/\1/p' "$$f"); \
		[ -n "$$subs" ] || { echo "    FAIL: $$f declares no '# Expected fail substring: \"...\"' line; without one, any fail passes it"; exit 1; }; \
		if out=$$(helm template global-chart-bad-values ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) $(HELM_API_VERSIONS) -f "$$f" 2>&1); then \
			echo "    FAIL: $$f should have been rejected but was accepted"; \
			exit 1; \
		elif helm lint $(STRICT) -f "$$f" ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) 2>&1 | grep -qF "$(SCHEMA_REJECTION)"; then \
			echo "    FAIL: $$f is rejected by values.schema.json; it belongs in tests/bad-values/schema/"; \
			exit 1; \
		else \
			printf '%s\n' "$$subs" | while IFS= read -r sub; do \
				printf '%s' "$$out" | grep -qF -- "$$sub" || { echo "    FAIL: $$f was rejected, but not by the fail it expects: missing \"$$sub\""; echo "          got: $$out"; exit 1; }; \
			done; \
		fi; \
	done
	@set -e; for f in tests/bad-values/skip-schema/*.yaml; do \
		[ -e "$$f" ] || { echo "    FAIL: tests/bad-values/skip-schema/ holds no fixture; green here would be vacuous"; exit 1; }; \
		subs=$$(sed -n 's/^# Expected fail substring: "\(.*\)"$$/\1/p' "$$f"); \
		[ -n "$$subs" ] || { echo "    FAIL: $$f declares no '# Expected fail substring: \"...\"' line; without one, any fail passes it"; exit 1; }; \
		if ! helm lint $(STRICT) -f "$$f" ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) 2>&1 | grep -qF "$(SCHEMA_REJECTION)"; then \
			echo "    FAIL: $$f is not rejected by values.schema.json; the guard is not shadowed, it belongs in tests/bad-values/fail/"; \
			exit 1; \
		elif out=$$(helm template global-chart-bad-values ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) --skip-schema-validation $(HELM_API_VERSIONS) -f "$$f" 2>&1); then \
			echo "    FAIL: $$f should have been rejected under --skip-schema-validation but was accepted"; \
			exit 1; \
		else \
			printf '%s\n' "$$subs" | while IFS= read -r sub; do \
				printf '%s' "$$out" | grep -qF -- "$$sub" || { echo "    FAIL: $$f was rejected, but not by the fail it expects: missing \"$$sub\""; echo "          got: $$out"; exit 1; }; \
			done; \
		fi; \
	done
	@python3 tests/bad-values/check-closure-coverage.py "$(SCHEMA_REJECTION)" $(STRICT)
	@echo "    OK: $(words $(wildcard tests/bad-values/*/*.yaml)) fixtures rejected, each by the mechanism its directory names"
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
			--include-crds >/dev/null; \
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
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/gateway.envoyproxy.io/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
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

# Three attempts five seconds apart, for a step that reaches a third-party host
# and can fail on a transient DNS or network error. No comma in the command:
# $(call) would split on it.
RETRY3 = for i in 1 2 3; do $(1) && break; echo "    attempt $$i/3 failed"; [ "$$i" = 3 ] && exit 1; sleep 5; done

# The download retries, and the recipe runs under `set -e` so a download that
# never lands stops here. Without it the failure surfaced two lines down as
# `chmod: cannot access .bin/kind`, which names the wrong thing: the file is
# missing because curl wrote nothing, not because of a permission problem.
kind-install: ## Download the kind binary into .bin/ (no-op if already there)
	@set -e; if [ ! -x "$(KIND)" ]; then \
		mkdir -p $(KIND_BIN_DIR); \
		os=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
		arch=$$(uname -m); \
		case "$$arch" in aarch64|arm64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; \
			*) echo "Unsupported architecture: $$arch"; exit 1 ;; esac; \
		echo "==> Downloading kind $(KIND_VERSION) ($$os/$$arch)..."; \
		for i in 1 2 3; do \
			curl -sfLo "$(KIND)" "https://kind.sigs.k8s.io/dl/$(KIND_VERSION)/kind-$$os-$$arch" && break; \
			echo "    download failed (attempt $$i/3)"; \
			[ "$$i" = 3 ] && { echo "==> Could not download kind"; exit 1; }; \
			sleep 5; \
		done; \
		chmod +x "$(KIND)"; \
	fi
	@$(KIND) version

kind-cluster: kind-install ## Create the e2e kind cluster (isolated kubeconfig, never ~/.kube/config)
	@if ! $(KIND) get clusters 2>/dev/null | grep -qx "$(KIND_CLUSTER)"; then \
		echo "==> Creating kind cluster $(KIND_CLUSTER)..."; \
		$(KIND) create cluster --name "$(KIND_CLUSTER)" --kubeconfig "$(KIND_KUBECONFIG)"; \
	fi
	@# A cluster from an earlier session survives a Docker restart stopped: kind
	@# still lists it, and a stopped container has no address to repoint at.
	@if [ "$$(docker inspect "$(KIND_CLUSTER)-control-plane" -f '{{.State.Running}}' 2>/dev/null)" = false ]; then \
		echo "==> Starting the stopped control-plane container $(KIND_CLUSTER)-control-plane..."; \
		docker start "$(KIND_CLUSTER)-control-plane" >/dev/null; \
		for i in $$(seq 1 60); do \
			docker exec "$(KIND_CLUSTER)-control-plane" kubectl --kubeconfig /etc/kubernetes/admin.conf \
				get --raw /readyz >/dev/null 2>&1 && break; \
			[ "$$i" = 60 ] && { echo "FAIL: the API server of $(KIND_CLUSTER) is not ready 120s after the start; run make kind-delete and retry"; exit 1; }; \
			sleep 2; \
		done; \
	fi
	@# When make runs inside a container the kubeconfig's 127.0.0.1 endpoint is the
	@# Docker *host*, not us: fall back to the control-plane container's own address.
	@if ! KUBECONFIG=$(KIND_KUBECONFIG) kubectl get nodes >/dev/null 2>&1; then \
		ip=$$(docker inspect "$(KIND_CLUSTER)-control-plane" -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'); \
		case "$$ip" in *.*) ;; *) echo "FAIL: $(KIND_CLUSTER)-control-plane has no IP address ($$ip); run make kind-delete and retry"; exit 1 ;; esac; \
		echo "==> Repointing kubeconfig at the control-plane container ($$ip)..."; \
		KUBECONFIG=$(KIND_KUBECONFIG) kubectl config set-cluster "kind-$(KIND_CLUSTER)" --server="https://$$ip:6443" >/dev/null; \
	fi
	@KUBECONFIG=$(KIND_KUBECONFIG) kubectl wait --for=condition=Ready node --all --timeout=180s

kind-keda: kind-cluster ## Install KEDA (operator + CRDs) into the e2e kind cluster
	@echo "==> Installing KEDA $(KEDA_VERSION)..."
	@mkdir -p $(KIND_BIN_DIR)
	@$(call RETRY3,$(HELM_REPO_ENV) helm repo add kedacore $(KEDA_REPO_URL) --force-update >/dev/null)
	@KUBECONFIG=$(KIND_KUBECONFIG) $(HELM_REPO_ENV) helm upgrade --install keda kedacore/keda \
		--version $(KEDA_VERSION) \
		--namespace $(KEDA_NAMESPACE) --create-namespace \
		--wait --timeout 300s >/dev/null
	@KUBECONFIG=$(KIND_KUBECONFIG) kubectl wait --for=condition=Established \
		crd/scaledobjects.keda.sh crd/triggerauthentications.keda.sh --timeout=60s >/dev/null
	@echo "    KEDA operator ready"

kind-eso: kind-cluster ## Install External Secrets Operator (operator + CRDs) and the e2e fake store
	@echo "==> Installing External Secrets Operator $(ESO_VERSION)..."
	@mkdir -p $(KIND_BIN_DIR)
	@$(call RETRY3,$(HELM_REPO_ENV) helm repo add external-secrets $(ESO_REPO_URL) --force-update >/dev/null)
	@KUBECONFIG=$(KIND_KUBECONFIG) $(HELM_REPO_ENV) helm upgrade --install external-secrets external-secrets/external-secrets \
		--version $(ESO_VERSION) \
		--namespace $(ESO_NAMESPACE) --create-namespace \
		--wait --timeout 300s >/dev/null
	@KUBECONFIG=$(KIND_KUBECONFIG) kubectl wait --for=condition=Established \
		crd/externalsecrets.external-secrets.io crd/clustersecretstores.external-secrets.io --timeout=60s >/dev/null
	@# The webhook answers only once its certificate is in place, so the first apply can bounce.
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
		KUBECONFIG=$(KIND_KUBECONFIG) kubectl apply -f tests/e2e/cluster-secret-store.yaml >/dev/null 2>&1 && break; \
		sleep 5; \
	done
	@KUBECONFIG=$(KIND_KUBECONFIG) kubectl wait --for=condition=Ready clustersecretstore/e2e-fake --timeout=120s >/dev/null
	@echo "    External Secrets Operator ready, fake ClusterSecretStore Ready"

kind-gateway-api: kind-cluster ## Install the Gateway API CRDs (standard channel) into the e2e kind cluster
	@echo "==> Installing Gateway API $(GATEWAY_API_VERSION) CRDs (standard channel)..."
	@KUBECONFIG=$(KIND_KUBECONFIG) kubectl apply --server-side --force-conflicts \
		-f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/standard-install.yaml >/dev/null
	@KUBECONFIG=$(KIND_KUBECONFIG) kubectl wait --for=condition=Established \
		$(GATEWAY_ROUTE_CRDS) --timeout=60s >/dev/null
	@echo "    Gateway API CRDs established"

kind-envoy-gateway: kind-cluster ## Install only the Envoy Gateway SecurityPolicy CRD into the e2e kind cluster (no controller)
	@echo "==> Installing Envoy Gateway $(ENVOY_GATEWAY_VERSION) SecurityPolicy CRD..."
	@kubectl --kubeconfig "$(KIND_KUBECONFIG)" apply --server-side --force-conflicts \
		-f https://raw.githubusercontent.com/envoyproxy/gateway/$(ENVOY_GATEWAY_VERSION)/charts/gateway-helm/crds/generated/gateway.envoyproxy.io_securitypolicies.yaml >/dev/null
	@kubectl --kubeconfig "$(KIND_KUBECONFIG)" wait --for=condition=Established \
		crd/securitypolicies.gateway.envoyproxy.io --timeout=60s >/dev/null
	@echo "    SecurityPolicy CRD established"

e2e-dryrun: kind-cluster kind-keda kind-eso kind-gateway-api kind-envoy-gateway ## Send every TEST_CASES scenario to the API server as a server-side dry run (routes, StatefulSets, every kind)
	@# A server-side dry run runs the API server's whole validation, the CRDs'
	@# OpenAPI schemas and CEL rules included, and persists nothing. It sees what
	@# kubeconform cannot: the rules between fields (a StatefulSet's rollingUpdate
	@# with OnDelete, two pod volumes of one name). It needs no controller and no
	@# Gateway: an unattached route is still a valid object. Every scenario is
	@# sent, so a new one is checked without being listed anywhere. printf, not
	@# echo: sh's echo turns a "\n" inside a manifest into a line break.
	@set -e; export KUBECONFIG=$(KIND_KUBECONFIG); routes=0; accepted=' (server dry run)$$'; \
	for entry in $(TEST_CASES); do \
		values="$${entry%%:*}"; \
		manifest=$$(helm template e2e-dryrun ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) -f "$$values" $(HELM_API_VERSIONS)); \
		n=$$(printf '%s\n' "$$manifest" | grep -cE '$(GATEWAY_ROUTE_KIND_RE)' || true); routes=$$((routes + n)); \
		printf '%s\n' "$$manifest" | grep -q '^kind: ' || { echo "    $$values: renders no object"; continue; }; \
		out=$$(printf '%s\n' "$$manifest" | kubectl apply --dry-run=server -n default -f - 2>&1) \
			|| { echo "FAIL: $$values rejected by the API server:"; printf '%s\n' "$$out" | grep -v "$$accepted"; exit 1; }; \
		echo "    $$values: $$(printf '%s\n' "$$out" | grep -c "$$accepted") object(s) accepted, $$n route(s)"; \
	done; \
	[ "$$routes" -gt 0 ] || { echo "FAIL: no TEST_CASES scenario renders a Gateway API route"; exit 1; }

bound-sweep: kind-cluster kind-keda kind-eso kind-gateway-api kind-envoy-gateway ## Every bound value the schema accepts on a scenario node, sent to the API server as a server-side dry run (issue #226)
	@echo "==> Sweeping the schema bounds against the API server..."
	@KUBECONFIG=$(KIND_KUBECONFIG) python3 tests/bad-values/bound-sweep.py ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) \
		$(foreach e,$(TEST_CASES),$(firstword $(subst :, ,$(e)))) -- $(HELM_API_VERSIONS)

e2e-routes: e2e-dryrun ## Alias of e2e-dryrun, which sends every route along with the rest

kind-argocd: kind-cluster ## Install Argo CD (core) into the e2e kind cluster
	@echo "==> Installing Argo CD $(ARGOCD_VERSION) (core)..."
	@KUBECONFIG=$(KIND_KUBECONFIG) kubectl create namespace $(ARGOCD_NAMESPACE) --dry-run=client -o yaml \
		| KUBECONFIG=$(KIND_KUBECONFIG) kubectl apply -f - >/dev/null
	@KUBECONFIG=$(KIND_KUBECONFIG) kubectl apply -n $(ARGOCD_NAMESPACE) --server-side --force-conflicts \
		-f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/core-install.yaml >/dev/null
	@KUBECONFIG=$(KIND_KUBECONFIG) kubectl -n $(ARGOCD_NAMESPACE) rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null
	@KUBECONFIG=$(KIND_KUBECONFIG) kubectl -n $(ARGOCD_NAMESPACE) rollout status deploy/argocd-repo-server --timeout=300s >/dev/null

kind-delete: ## Delete the e2e kind cluster
	@if [ -x "$(KIND)" ]; then $(KIND) delete cluster --name "$(KIND_CLUSTER)"; fi
	@rm -f "$(KIND_KUBECONFIG)" "$(HELM_FLOOR_KUBECONFIG)"

check-helm-floor: kind-cluster ## Assert NOTES.txt warns on a Helm below 3.18.6
	@# NOTES.txt renders only on install/upgrade, and Helm 3's --dry-run=client
	@# still checks the cluster is reachable, so this borrows the kind cluster.
	@# The helm container reaches it on the kind network, by container name.
	@echo "==> Checking the Helm floor warning with $(HELM_FLOOR_IMAGE)..."
	@sed "s#server: .*#server: https://$(KIND_CLUSTER)-control-plane:6443#" $(KIND_KUBECONFIG) > $(HELM_FLOOR_KUBECONFIG)
	@out=$$(docker run --rm --network kind \
		-v $(HELM_FLOOR_KUBECONFIG):/kubeconfig:ro -e KUBECONFIG=/kubeconfig \
		-v $(CURDIR)/$(CHART_DIR)/$(GLOBAL_CHART_NAME):/chart:ro \
		$(HELM_FLOOR_IMAGE) install floor /chart --dry-run=client \
		--set workloads.web.image=nginx:1.25 2>&1) \
		|| { echo "FAIL: $(HELM_FLOOR_IMAGE) did not render the chart:"; printf '%s\n' "$$out" | tail -5; exit 1; }; \
	printf '%s\n' "$$out" | grep -q "is below 3.18.6" \
		|| { echo "FAIL: NOTES.txt did not warn on $(HELM_FLOOR_IMAGE)"; exit 1; }
	@echo "    warning shown below the floor"

e2e: kind-cluster kind-keda kind-eso check-helm-floor e2e-dryrun bound-sweep ## Install/upgrade/rollback/uninstall tests/e2e/values.yaml on kind and assert the hook lifecycle
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
		[ "$$(kubectl -n $$ns get job $$rel-$(GLOBAL_CHART_NAME)-app-pre-install-$$hook -o jsonpath='{.spec.template.spec.serviceAccountName}')" = "$$rel-$(GLOBAL_CHART_NAME)-app-hook" ] \
			|| { echo "FAIL: pre-install hook '$$hook' did not run as the workload SA copy <sa>-hook (ADR 0011)"; exit 1; }; \
	done; \
	echo "    both pre-install hooks bound to the chart-created ServiceAccount succeeded"; \
	echo "    ... as its hook copy <sa>-hook, never under the real SA's name (ADR 0011)"; \
	echo "    both read the ExternalSecret's value through its hook copy, envFrom and volume (issue #110)"; \
	kubectl -n $$ns wait --for=delete externalsecret/$$rel-$(GLOBAL_CHART_NAME)-e2e-env-hook \
		secret/$$rel-$(GLOBAL_CHART_NAME)-e2e-env-hook --timeout=60s >/dev/null 2>&1 \
		|| { echo "FAIL: the ExternalSecret hook copy or its Secret survived the hook phase"; \
		     kubectl -n $$ns get externalsecret,secret; exit 1; }; \
	echo "    ExternalSecret hook copy deleted, its Secret garbage-collected"; \
	echo "    the negative-weight hook found its prerequisite ConfigMap (weight invariant holds)"; \
	kubectl -n $$ns wait --for=delete sa/$$rel-$(GLOBAL_CHART_NAME)-app-hook --timeout=60s >/dev/null 2>&1 \
		|| { echo "FAIL: the workload SA hook copy survived the hook phase"; kubectl -n $$ns get sa; exit 1; }; \
	kubectl -n $$ns get sa $$rel-$(GLOBAL_CHART_NAME)-app -o jsonpath='{.metadata.annotations}' | grep -q 'helm.sh/hook' \
		&& { echo "FAIL: the surviving SA is the hook copy, not the real one"; exit 1; } || true; \
	echo "    hook-prerequisite SA copy cleaned up, real SA in place"; \
	[ "$$(kubectl -n $$ns get job $$rel-$(GLOBAL_CHART_NAME)-pre-install-rbac-read -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ] \
		|| { echo "FAIL: the pre-install hook could not use the rbacs.roles copy (ADR 0010)"; exit 1; }; \
	echo "    pre-install hook ran as the rbacs.roles SA copy, with the Role copy's rules"; \
	kubectl -n $$ns wait --for=delete sa/e2e-hook-reader-hook role/e2e-hook-reader-hook \
		rolebinding/e2e-hook-reader-rolebinding-hook --timeout=60s >/dev/null 2>&1 \
		|| { echo "FAIL: the rbacs.roles hook copies survived the hook phase"; kubectl -n $$ns get sa,role,rolebinding; exit 1; }; \
	kubectl -n $$ns get sa/e2e-hook-reader role/e2e-hook-reader rolebinding/e2e-hook-reader-rolebinding >/dev/null \
		|| { echo "FAIL: the real rbacs.roles resources are missing"; exit 1; }; \
	echo "    rbacs.roles hook copies deleted, real SA/Role/RoleBinding in place"; \
	[ "$$(kubectl -n $$ns get deploy $$rel-$(GLOBAL_CHART_NAME)-app -o jsonpath='{.spec.template.spec.containers[0].command}')" = '["sh","-c"]' ] \
		|| { echo "FAIL: Deployment command not rendered (issue #72 regression)"; exit 1; }; \
	echo "    Deployment command/args rendered"; \
	cron_sa=$$(kubectl -n $$ns get cronjob $$rel-$(GLOBAL_CHART_NAME)-cleanup -o jsonpath='{.spec.jobTemplate.spec.template.spec.serviceAccountName}'); \
	kubectl -n $$ns get sa "$$cron_sa" >/dev/null 2>&1 \
		|| { echo "FAIL: root-level CronJob references ServiceAccount '$$cron_sa', which no manifest creates"; exit 1; }; \
	echo "    root-level CronJob's ServiceAccount exists in the cluster"; \
	echo "==> Waiting for Service endpoints..."; \
	for d in app web; do \
		kubectl -n $$ns rollout status deploy/$$rel-$(GLOBAL_CHART_NAME)-$$d --timeout=180s >/dev/null \
			|| { echo "FAIL: Deployment '$$d' never became available"; exit 1; }; \
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
	sts=$$rel-$(GLOBAL_CHART_NAME)-store; \
	kubectl -n $$ns rollout status sts/$$sts --timeout=180s >/dev/null \
		|| { echo "FAIL: StatefulSet 'store' never became ready (issue #211)"; kubectl -n $$ns get sts,pod,pvc; exit 1; }; \
	kubectl -n $$ns get svc $$sts-headless -o jsonpath='{.spec.clusterIP}' | grep -qx None \
		|| { echo "FAIL: the StatefulSet's headless Service is missing"; exit 1; }; \
	[ "$$(kubectl -n $$ns get pvc data-$$sts-0 -o jsonpath='{.status.phase}')" = "Bound" ] \
		|| { echo "FAIL: the claim data-$$sts-0 is not Bound"; kubectl -n $$ns get pvc; exit 1; }; \
	kubectl -n $$ns exec $$sts-0 -- sh -c 'echo e2e > /data/marker'; \
	kubectl -n $$ns delete pod $$sts-0 --wait=true >/dev/null; \
	kubectl -n $$ns wait --for=condition=Ready pod/$$sts-0 --timeout=180s >/dev/null \
		|| { echo "FAIL: the StatefulSet did not recreate its pod"; exit 1; }; \
	[ "$$(kubectl -n $$ns exec $$sts-0 -- cat /data/marker)" = "e2e" ] \
		|| { echo "FAIL: the file written on the claim did not survive the pod's replacement"; exit 1; }; \
	echo "    StatefulSet ready behind its headless Service; its claim kept the data across a pod replacement"; \
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
	echo "    upgrading to the same chart under another version: every helm.sh/chart label moves,"; \
	echo "    so a version-bearing label in an immutable field (selector, volumeClaimTemplates) fails here"; \
	upgrade_dir=$(KIND_BIN_DIR)/e2e-upgrade; rm -rf "$$upgrade_dir"; \
	helm package ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) -d "$$upgrade_dir" \
		--version "$$(helm show chart ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) | awk '/^version:/ {print $$2}')-e2e.upgrade" >/dev/null; \
	helm upgrade $$rel "$$upgrade_dir"/$(GLOBAL_CHART_NAME)-*.tgz -f $(E2E_VALUES) \
		--set-string workloads.store.podAnnotations.e2e-upgrade=1 \
		--namespace $$ns --timeout 180s >/dev/null; \
	case "$$(kubectl -n $$ns get sts $$sts -o jsonpath='{.metadata.labels.helm\.sh/chart}')" in *-e2e.upgrade) ;; \
		*) echo "FAIL: the upgrade did not apply the other chart version"; exit 1 ;; esac; \
	kubectl -n $$ns rollout status sts/$$sts --timeout=180s >/dev/null \
		|| { echo "FAIL: the StatefulSet did not roll out after the upgrade"; exit 1; }; \
	[ "$$(kubectl -n $$ns get pod $$sts-0 -o jsonpath='{.metadata.annotations.e2e-upgrade}')" = "1" ] \
		|| { echo "FAIL: the upgrade did not replace the StatefulSet's pod: the data check below would prove nothing"; exit 1; }; \
	[ "$$(kubectl -n $$ns exec $$sts-0 -- cat /data/marker)" = "e2e" ] \
		|| { echo "FAIL: the file written on the claim did not survive the upgrade (issue #211)"; exit 1; }; \
	echo "    the upgrade replaced the StatefulSet's pod, and its claim kept the data"; \
	[ "$$sa_before" = "$$(kubectl -n $$ns get sa $$rel-$(GLOBAL_CHART_NAME)-app -o jsonpath='{.metadata.uid}')" ] \
		|| { echo "FAIL: the ServiceAccount was recreated, bound tokens would be invalidated"; exit 1; }; \
	echo "    upgrade kept the ServiceAccount identity"; \
	[ "$$(kubectl -n $$ns get job $$rel-$(GLOBAL_CHART_NAME)-app-pre-upgrade-migration -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ] \
		|| { echo "FAIL: the pre-upgrade hook bound to the workload SA did not succeed"; exit 1; }; \
	[ "$$(kubectl -n $$ns get job $$rel-$(GLOBAL_CHART_NAME)-app-pre-upgrade-migration -o jsonpath='{.spec.template.spec.serviceAccountName}')" = "$$rel-$(GLOBAL_CHART_NAME)-app-hook" ] \
		|| { echo "FAIL: the pre-upgrade hook did not run as the workload SA copy (ADR 0011)"; exit 1; }; \
	[ "$$(kubectl -n $$ns get job $$rel-$(GLOBAL_CHART_NAME)-app-pre-upgrade-migration -o jsonpath='{.spec.template.spec.initContainers[0].restartPolicy}')" = "Always" ] \
		|| { echo "FAIL: the pre-upgrade hook's sidecar reached the API server without restartPolicy: Always (issue #262)"; exit 1; }; \
	echo "    pre-upgrade hook completed beside its native sidecar, which never exits on its own (issue #262)"; \
	kubectl -n $$ns wait --for=delete sa/$$rel-$(GLOBAL_CHART_NAME)-app-hook --timeout=60s >/dev/null 2>&1 \
		|| { echo "FAIL: the workload SA hook copy survived the pre-upgrade phase"; kubectl -n $$ns get sa; exit 1; }; \
	echo "    pre-upgrade hook ran as the workload SA copy beside the live SA, copy cleaned up (issue #141)"; \
	[ "$$(kubectl -n $$ns get job $$rel-$(GLOBAL_CHART_NAME)-pre-upgrade-rbac-read -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ] \
		|| { echo "FAIL: the pre-upgrade hook could not use the rbacs.roles copy (ADR 0010)"; exit 1; }; \
	echo "    pre-upgrade hook ran as the rbacs.roles SA copy, beside the live one"; \
	{ [ "$$(kubectl -n $$ns get deployment $$rel-$(GLOBAL_CHART_NAME)-worker -o jsonpath='{.spec.replicas}')" = "3" ] \
		|| { echo "FAIL: upgrade reset spec.replicas on a KEDA-scaled Deployment"; exit 1; }; }; \
	echo "    upgrade left spec.replicas to the autoscaler"; \
	echo "==> Rolling back to revision 1 (exercises the pre-rollback hook)..."; \
	sa_before=$$(kubectl -n $$ns get sa $$rel-$(GLOBAL_CHART_NAME)-app -o jsonpath='{.metadata.uid}'); \
	reader_before=$$(kubectl -n $$ns get sa e2e-hook-reader -o jsonpath='{.metadata.uid}'); \
	helm rollback $$rel 1 -n $$ns --wait --timeout 180s >/dev/null; \
	[ "$$(kubectl -n $$ns get job $$rel-$(GLOBAL_CHART_NAME)-pre-rollback-rbac-read -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ] \
		|| { echo "FAIL: the pre-rollback hook could not use the rbacs.roles and ExternalSecret copies (issue #143)"; exit 1; }; \
	[ "$$(kubectl -n $$ns get job $$rel-$(GLOBAL_CHART_NAME)-pre-rollback-rbac-read -o jsonpath='{.spec.template.spec.serviceAccountName}')" = "e2e-hook-reader-hook" ] \
		|| { echo "FAIL: the pre-rollback hook did not run as the rbacs.roles SA copy (ADR 0010)"; exit 1; }; \
	echo "    pre-rollback hook ran as the rbacs.roles SA copy and read the ExternalSecret copy"; \
	kubectl -n $$ns wait --for=delete sa/e2e-hook-reader-hook role/e2e-hook-reader-hook \
		rolebinding/e2e-hook-reader-rolebinding-hook externalsecret/$$rel-$(GLOBAL_CHART_NAME)-e2e-env-hook \
		secret/$$rel-$(GLOBAL_CHART_NAME)-e2e-env-hook --timeout=60s >/dev/null 2>&1 \
		|| { echo "FAIL: hook copies survived the pre-rollback phase"; kubectl -n $$ns get sa,role,rolebinding,externalsecret,secret; exit 1; }; \
	[ "$$sa_before" = "$$(kubectl -n $$ns get sa $$rel-$(GLOBAL_CHART_NAME)-app -o jsonpath='{.metadata.uid}')" ] \
		&& [ "$$reader_before" = "$$(kubectl -n $$ns get sa e2e-hook-reader -o jsonpath='{.metadata.uid}')" ] \
		|| { echo "FAIL: rollback recreated a real ServiceAccount, bound tokens would be invalidated"; exit 1; }; \
	echo "    pre-rollback copies cleaned up, real ServiceAccounts kept their UID"; \
	echo "==> Uninstalling and checking for orphaned hook resources..."; \
	helm uninstall $$rel -n $$ns --timeout 180s >/dev/null; \
	[ "$$(kubectl -n $$ns get job $$rel-$(GLOBAL_CHART_NAME)-post-delete-farewell -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ] \
		|| { echo "FAIL: the post-delete hook did not read the ExternalSecret through its copy"; exit 1; }; \
	echo "    post-delete hook read the ExternalSecret through its copy, after the real one was gone"; \
	[ "$$(kubectl -n $$ns get job $$rel-$(GLOBAL_CHART_NAME)-post-delete-rbac-read -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ] \
		|| { echo "FAIL: the post-delete hook could not use the rbacs.roles copy (ADR 0010)"; exit 1; }; \
	echo "    post-delete hook ran as the rbacs.roles SA copy, after the real one was gone"; \
	kubectl -n $$ns wait --for=delete secret/$$rel-$(GLOBAL_CHART_NAME)-e2e-env secret/$$rel-$(GLOBAL_CHART_NAME)-e2e-conf \
		secret/$$rel-$(GLOBAL_CHART_NAME)-e2e-env-hook secret/$$rel-$(GLOBAL_CHART_NAME)-e2e-conf-hook --timeout=60s >/dev/null 2>&1 || true; \
	orphans=$$(kubectl -n $$ns get sa,cm,secret,role,rolebinding --no-headers 2>/dev/null \
		| grep -v 'serviceaccount/default\|kube-root-ca.crt' || true); \
	if [ -n "$$orphans" ]; then echo "FAIL: hook resources orphaned after uninstall:"; echo "$$orphans"; exit 1; fi; \
	echo "    no orphaned ConfigMap/Secret/ServiceAccount/Role/RoleBinding"; \
	keda_orphans=$$(kubectl -n $$ns get scaledobject,triggerauthentication,hpa,externalsecret --no-headers 2>/dev/null || true); \
	if [ -n "$$keda_orphans" ]; then echo "FAIL: KEDA resources orphaned after uninstall:"; echo "$$keda_orphans"; exit 1; fi; \
	echo "    no orphaned ScaledObject/TriggerAuthentication/ExternalSecret, derived HPA garbage-collected"; \
	kubectl -n $$ns get pvc data-$$rel-$(GLOBAL_CHART_NAME)-store-0 >/dev/null 2>&1 \
		|| { echo "FAIL: helm uninstall deleted the StatefulSet's claim (ADR 0020)"; exit 1; }; \
	echo "    the StatefulSet's claim survived the uninstall (persistentVolumeClaimRetentionPolicy Retain)"; \
	echo "==> e2e passed"

e2e-argocd: kind-cluster kind-eso kind-argocd ## Sync tests/e2e/argocd through Argo CD on kind and assert the hook copies (issues #149, #164)
	@KUBECONFIG=$(KIND_KUBECONFIG) ARGOCD_NAMESPACE=$(ARGOCD_NAMESPACE) tests/e2e/argocd/run.sh ./$(CHART_DIR)/$(GLOBAL_CHART_NAME)

install-test01: ## Install test01 (has kubectl pre-step; or use: make install SCENARIO=test01)
	kubectl apply -f tests/test01/test01.yaml || true
	helm upgrade --install test ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) \
		-f tests/test01/values.01.yaml \
		--namespace test01 \
		--create-namespace

# ============================================================================
# Render (single template debugging)
# ============================================================================

render: ## Render a values file, with the CRD API versions (usage: make render VALUES=<file> [TEMPLATE=<name>] [SKIP_SCHEMA=1])
	@if [ -z "$(VALUES)" ]; then \
		echo "Usage: make render VALUES=<values-file> [TEMPLATE=<template-name>] [SKIP_SCHEMA=1]"; \
		echo "Example: make render VALUES=tests/test01/values.01.yaml TEMPLATE=workload.yaml"; \
		echo "TEMPLATE left out renders the whole chart; SKIP_SCHEMA=1 adds --skip-schema-validation"; \
		exit 1; \
	fi
	helm template test-release ./$(CHART_DIR)/$(GLOBAL_CHART_NAME) \
		-f $(VALUES) \
		$(HELM_API_VERSIONS) \
		$(if $(TEMPLATE),-s templates/$(TEMPLATE)) \
		$(if $(SKIP_SCHEMA),--skip-schema-validation)

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
