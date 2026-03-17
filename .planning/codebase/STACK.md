# Technology Stack

**Analysis Date:** 2026-03-17

## Languages

**Primary:**
- Go Template (Helm) - All chart templates in `charts/global-chart/templates/`
- YAML - Values files, test suites, CI workflows, configuration

**Secondary:**
- Makefile - Build, test, lint, packaging automation (`Makefile`)

## Runtime

**Environment:**
- Kubernetes >= 1.19.0 (enforced via `kubeVersion` in `charts/global-chart/Chart.yaml`)

**Package Manager:**
- Helm v3 (CLI tooling; no lockfile - chart has no dependencies)
- Lockfile: Not applicable (no chart dependencies declared in Chart.yaml)

## Frameworks

**Core:**
- Helm v3.19.0 - Chart templating and packaging (pinned in CI via `azure/setup-helm@v4`)
- Go Templates - Native Helm template engine used across all `templates/*.yaml` files

**Testing:**
- helm-unittest v3.19.0-1.0.3 - Unit test runner via Docker image `helmunittest/helm-unittest:3.19.0-1.0.3`
- 16 test suites, 220 tests in `charts/global-chart/tests/`

**Build/Dev:**
- Docker - Required for `make unit-test`, `make kube-linter`, `make generate-docs` (no local plugin install needed)
- Make - All developer workflows defined in `Makefile`
- helm-docs (jnorwood/helm-docs:latest) - Auto-generates README from value annotations
- kube-linter (ghcr.io/stackrox/kube-linter) - Static analysis of rendered manifests; config in `.kube-linter-config.yaml`

## Key Dependencies

**Critical:**
- `external-secrets.io/v1` CRD - Required when `externalSecrets` values are configured; the chart generates `ExternalSecret` objects (no operator bundled, must be pre-installed in cluster)

**Infrastructure:**
- `charts/raw/` - Secondary bundled chart for deploying raw Kubernetes resources; version 0.1.0

## Configuration

**Environment:**
- No runtime environment variables; chart is purely declarative Helm YAML
- Configuration is entirely via Helm values (`charts/global-chart/values.yaml`)
- Key configurable globals: `global.imageRegistry`, `global.imagePullSecrets`

**Build:**
- `Makefile` - All build targets and Docker image versions
- `.kube-linter-config.yaml` - kube-linter rules (all built-in enabled, several excluded for Helm compatibility)
- `coderabbit.yaml` - AI code review configuration (yamllint, gitleaks, checkov, actionlint enabled)
- `renovate.json` - Dependency update automation using `config:recommended` preset

## Platform Requirements

**Development:**
- Helm v3 CLI (local install)
- Docker (for unit tests, kube-linter, helm-docs)
- kubectl (optional, for `make install-test01`)
- `make` (GNU Make)

**Production:**
- Kubernetes cluster >= 1.19.0
- Helm v3 for chart installation
- External Secrets Operator pre-installed if using `externalSecrets` feature
- Ingress controller (nginx assumed by default `className: "nginx"`) if using `ingress`

---

*Stack analysis: 2026-03-17*
