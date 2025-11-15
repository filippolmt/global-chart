STRICT ?= --strict

GLOBAL_CHART_NAME := global-chart
RAW_CHART_NAME := raw
CHART_DIR := charts

KUBE_LINTER_VERSION := $(shell if [ "$(shell uname -m)" = "x86_64" ]; then echo "latest-alpine-amd64"; else echo "latest-alpine-arm64"; fi)
KUBE_LINTER_IMAGE := ghcr.io/stackrox/kube-linter:$(KUBE_LINTER_VERSION)
KUBE_LINTER_OUTPUT_DIR := generated-manifests/kube-linter
KUBE_LINTER_CASES := \
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
	tests/rbac.yaml:rbac:rbac

lint-chart:
	helm lint $(STRICT) -f tests/test01/values.01.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/values.02.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/values.03.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/mountedcm1.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/mountedcm2.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/cron-only.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/hook-only.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/externalsecret-only.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/ingress-custom.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/external-ingress.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/rbac.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}

generate-template-mountedcm1:
	@rm -r generated-manifests/mountedcm1 || true
	@mkdir -p generated-manifests/mountedcm1
	helm template test-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/mountedcm1.yaml \
		--namespace mountedcm1 \
		--output-dir generated-manifests/mountedcm1 \
		--include-crds

generate-templates: lint-chart
	@rm -r generated-manifests || true
	@mkdir -p generated-manifests
	helm template test01-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/test01/values.01.yaml \
		--namespace test \
		--output-dir generated-manifests/01 \
		--include-crds
	helm template test02-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/values.02.yaml \
		--namespace test \
		--output-dir generated-manifests/02 \
		--include-crds
	helm template test03-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/values.03.yaml \
		--namespace test \
		--output-dir generated-manifests/03 \
		--include-crds
	helm template test-mountedcm1-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/mountedcm1.yaml \
		--namespace mountedcm1 \
		--output-dir generated-manifests/mountedcm1 \
		--include-crds
	helm template test-mountedcm2-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/mountedcm2.yaml \
		--namespace mountedcm2 \
		--output-dir generated-manifests/mountedcm2 \
		--include-crds
	helm template test-cron-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/cron-only.yaml \
		--namespace cron \
		--output-dir generated-manifests/cron \
		--include-crds
	helm template test-hook-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/hook-only.yaml \
		--namespace hooks \
		--output-dir generated-manifests/hooks \
		--include-crds
	helm template test-es-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/externalsecret-only.yaml \
		--namespace externalsecrets \
		--output-dir generated-manifests/externalsecret \
		--include-crds
	helm template test-ingress-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/ingress-custom.yaml \
		--namespace ingress \
		--output-dir generated-manifests/ingress \
		--include-crds
	helm template test-external-ingress-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/external-ingress.yaml \
		--namespace ingress \
		--output-dir generated-manifests/external-ingress \
		--include-crds
	helm template test-rbac-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/rbac.yaml \
		--namespace rbac \
		--output-dir generated-manifests/rbac \
		--include-crds

helm-install-${GLOBAL_CHART_NAME}-01:
	kubectl apply -f tests/test01/test01.yaml || true
	helm upgrade --install test ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/test01/values.01.yaml \
		--namespace test01 \
		--create-namespace

helm-install-${GLOBAL_CHART_NAME}-02:
	helm upgrade --install test ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/values.02.yaml \
		--namespace test02 \
		--create-namespace

helm-install-${GLOBAL_CHART_NAME}-03:
	helm upgrade --install test ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/values.03.yaml \
		--namespace test03 \
		--create-namespace

kube-linter-manifests:
	@rm -rf $(KUBE_LINTER_OUTPUT_DIR) || true
	@mkdir -p $(KUBE_LINTER_OUTPUT_DIR)
	@set -e; for entry in $(KUBE_LINTER_CASES); do \
		values="$${entry%%:*}"; rest="$${entry#*:}"; namespace="$${rest%%:*}"; slug="$${rest##*:}"; \
		out_dir="$(KUBE_LINTER_OUTPUT_DIR)/$${slug}"; \
		mkdir -p "$${out_dir}"; \
		helm template "lint-$${slug}-$(GLOBAL_CHART_NAME)" "./$(CHART_DIR)/$(GLOBAL_CHART_NAME)" \
			-f "$${values}" \
			--namespace "$${namespace}" \
			--output-dir "$${out_dir}" \
			--include-crds; \
	done

kube-linter: kube-linter-manifests
	@docker run --rm \
		-v $(PWD):/workspace \
		$(KUBE_LINTER_IMAGE) \
		lint "/workspace/$(KUBE_LINTER_OUTPUT_DIR)" \
		--config "/workspace/.kube-linter-config.yaml"

generate-docs:
	@docker run --rm --volume "$$(pwd)/./${CHART_DIR}/${GLOBAL_CHART_NAME}:/helm-docs" -u $$(id -u) jnorwood/helm-docs:latest --sort-values-order file
	@docker run --rm --volume "$$(pwd)/./${CHART_DIR}/${RAW_CHART_NAME}:/helm-docs" -u $$(id -u) jnorwood/helm-docs:latest --sort-values-order file

build-chart-to-test-registry:
	helm package ${CHART_DIR}/${GLOBAL_CHART_NAME}

helm-install-${GLOBAL_CHART_NAME}-mountedcm1:
	helm upgrade --install test ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/mountedcm1.yaml \
		--namespace mountedcm1 \
		--create-namespace

helm-install-${GLOBAL_CHART_NAME}-mountedcm2:
	helm upgrade --install test ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/mountedcm2.yaml \
		--namespace mountedcm2 \
		--create-namespace

.PHONY: kube-linter kube-linter-manifests
