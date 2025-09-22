STRICT ?= --strict

GLOBAL_CHART_NAME := global-chart
RAW_CHART_NAME := raw
CHART_DIR := charts

lint-chart:
	helm lint $(STRICT) -f tests/test01/values.01.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/values.02.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/values.03.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/mountedcm1.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/mountedcm2.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}


generate-template-mountedcm1:
	@rm -r generated-manifests/mountedcm1 || true
	@mkdir -p generated-manifests/mountedcm1
	helm template test-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/mountedcm1.yaml \
		--namespace mountedcm1 \
		--output-dir generated-manifests/mountedcm1 \
		--include-crds
generate-template-mountedcm2:
	@rm -r generated-manifests/mountedcm2 || true
	@mkdir -p generated-manifests/mountedcm2
	helm template test-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/mountedcm2.yaml \
		--namespace mountedcm2 \
		--output-dir generated-manifests/mountedcm2 \
		--include-crds

generate-template-test01:
	@rm -r generated-manifests/01 || true
	@mkdir -p generated-manifests/01
	helm template test01-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/test01/values.01.yaml \
		--namespace test \
		--output-dir generated-manifests/01 \
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

kube-linter:
	@docker run -v $(PWD)/${GLOBAL_CHART_NAME}:/dir ghcr.io/stackrox/kube-linter:v0.6.8-alpine lint /dir

generate-docs:
	@docker run --rm --volume "$$(pwd)/./${CHART_DIR}/${GLOBAL_CHART_NAME}:/helm-docs" -u $$(id -u) jnorwood/helm-docs:latest --sort-values-order file
	@docker run --rm --volume "$$(pwd)/./${CHART_DIR}/${RAW}:/helm-docs" -u $$(id -u) jnorwood/helm-docs:latest --sort-values-order file

build-chart-to-test-registry:
	helm package ${GLOBAL_CHART_NAME}

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

