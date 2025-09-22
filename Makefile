STRICT ?= --strict

GLOBAL_CHART_NAME := global-chart
RAW_CHART_NAME := raw
CHART_DIR := charts

lint-chart:
	helm lint $(STRICT) -f tests/test01/values.01.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/values.02.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/values.03.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/dynamics1.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}
	helm lint $(STRICT) -f tests/dynamics2.yaml ./${CHART_DIR}/${GLOBAL_CHART_NAME}


generate-template-dynamics1:
	@rm -r generated-manifests/dynamics1 || true
	@mkdir -p generated-manifests/dynamics1
	helm template test-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/dynamics1.yaml \
		--namespace dynamics1 \
		--output-dir generated-manifests/dynamics1 \
		--include-crds
generate-template-dynamics2:
	@rm -r generated-manifests/dynamics2 || true
	@mkdir -p generated-manifests/dynamics2
	helm template test-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/dynamics2.yaml \
		--namespace dynamics2 \
		--output-dir generated-manifests/dynamics2 \
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
	helm template test-dynamics1-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/dynamics1.yaml \
		--namespace dynamics1 \
		--output-dir generated-manifests/dynamics1 \
		--include-crds
	helm template test-dynamics2-${GLOBAL_CHART_NAME} ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/dynamics2.yaml \
		--namespace dynamics2 \
		--output-dir generated-manifests/dynamics2 \
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

helm-install-${GLOBAL_CHART_NAME}-dynamics1:
	helm upgrade --install test ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/dynamics1.yaml \
		--namespace dynamics1 \
		--create-namespace

helm-install-${GLOBAL_CHART_NAME}-dynamics2:
	helm upgrade --install test ./${CHART_DIR}/${GLOBAL_CHART_NAME} \
		-f tests/dynamics2.yaml \
		--namespace dynamics2 \
		--create-namespace

