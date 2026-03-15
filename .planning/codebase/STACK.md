# Technology Stack

**Analysis Date:** 2026-03-15

## Languages

**Primary:**
- YAML - Helm values, templates, test fixtures, CI/CD workflows
- Go Template (Helm templating) - All chart templates in `charts/global-chart/templates/`

**Secondary:**
- Makefile (GNU Make) - Build automation in `Makefile`
- Shell (bash) - Inline scripts in `Makefile` targets

## Runtime

**Environment:**
- Kubernetes >=1.19.0-0 (target deployment environment, enforced in `charts/global-chart/Chart.yaml`)
- Docker (required locally for unit tests, kube-linter, helm-docs — no local plugin install needed)

**Package Manager:**
- Helm v3.19.0 (set explicitly in CI via `azure/setup-helm@v4`)
- No lockfile — chart has no sub-chart dependencies (`charts/global-chart/charts/` is empty)

## Frameworks

**Core:**
- Helm v3 (apiVersion: v2) - Chart packaging and templating engine (`charts/global-chart/Chart.yaml`)

**Testing:**
- helm-unittest v1.0.3 for Helm 3.19.0 — Docker image `helmunittest/helm-unittest:3.19.0-1.0.3` — unit test framework for Helm charts (`charts/global-chart/tests/`)

**Build/Dev:**
- GNU Make — task runner for all dev operations (`Makefile`)
- Docker — required for unit tests, kube-linter, helm-docs (no local install of those tools needed)

## Key Dependencies

**Critical:**
- Helm v3.19.0 — required for template rendering, linting, packaging, and install
- helm-unittest `helmunittest/helm-unittest:3.19.0-1.0.3` — runs 220 tests across 16 suites
- External Secrets Operator (cluster-side CRD) — required at runtime when `externalSecrets` values are used; chart generates `ExternalSecret` resources (`apiVersion: external-secrets.io/v1`)

**Infrastructure:**
- `ghcr.io/stackrox/kube-linter:latest-alpine-{amd64|arch64}` — static analysis of generated manifests (optional, `make kube-linter`)
- `jnorwood/helm-docs:latest` — auto-generates README from value annotations (`make generate-docs`)
- `busybox:1.36` — used in `helm test` connection pod (`charts/global-chart/templates/tests/test-connection.yaml`)

## Configuration

**Environment:**
- No application-level environment variables required to build or test this chart
- `global.imageRegistry` and `global.imagePullSecrets` are Helm values (not env vars) for registry configuration

**Build:**
- `Makefile` — primary build config; defines `HELM_UNITTEST_IMAGE`, `KUBE_LINTER_IMAGE`, `HELM_DOCS_IMAGE` constants
- `charts/global-chart/Chart.yaml` — chart metadata, version (`1.3.0`), Kubernetes version constraint
- `charts/global-chart/values.yaml` — all configurable defaults; no external config files required
- `.kube-linter-config.yaml` — kube-linter rule configuration (referenced by `make kube-linter`)
- `renovate.json` — Renovate Bot config for automated dependency updates (`config:recommended` preset)
- `coderabbit.yaml` — CodeRabbit AI review config (yamllint, gitleaks, checkov, actionlint enabled)

## Platform Requirements

**Development:**
- Helm v3.19.0 installed locally
- Docker (for unit tests, kube-linter, helm-docs)
- GNU Make
- Optional: kubectl (for `make install-test01` pre-step)

**Production:**
- Kubernetes >=1.19.0-0
- Helm v3 for chart installation
- External Secrets Operator installed on cluster (only if using `externalSecrets` values)
- Nginx Ingress Controller (default `className: "nginx"`, configurable)

## Secondary Chart

A minimal companion chart exists at `charts/raw/` (version 0.1.0) that renders arbitrary Kubernetes resources from `values.resources[]` using `toYaml`. It has no dependencies and no helpers.

---

*Stack analysis: 2026-03-15*
