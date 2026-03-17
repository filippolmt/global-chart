# External Integrations

**Analysis Date:** 2026-03-17

## APIs & External Services

**Code Review:**
- CodeRabbit - Automated AI code review on pull requests
  - Config: `coderabbit.yaml`
  - Auth: GitHub App (no additional secrets required)
  - Tools enabled: yamllint, gitleaks, checkov, actionlint, languagetool, github-checks

**Dependency Updates:**
- Renovate Bot - Automated dependency update PRs
  - Config: `renovate.json`
  - Preset: `config:recommended`
  - Scope: GitHub Actions, Docker image tags in Makefile

## Data Storage

**Databases:**
- Not applicable (this is a Helm chart, not an application)

**File Storage:**
- Local filesystem: `generated-manifests/` - Helm-rendered YAML output (gitignored, generated at build time)

**Caching:**
- None

## Authentication & Identity

**Auth Provider:**
- GitHub Token (`secrets.GITHUB_TOKEN`) - Used by chart-releaser in release workflow
  - Implementation: Automatic GitHub Actions secret; no manual configuration required
  - Scope: Publishing chart releases to GitHub Pages / Releases

## Monitoring & Observability

**Error Tracking:**
- None (Helm chart repository; no runtime application)

**Logs:**
- GitHub Actions workflow logs for CI/CD runs

## CI/CD & Deployment

**Hosting:**
- GitHub - Source repository at `https://github.com/filippomerante/global-chart`
- GitHub Pages / GitHub Releases - Chart distribution via `helm/chart-releaser-action@v1.7.0`

**CI Pipeline:**
- GitHub Actions - Two workflows:
  - `.github/workflows/helm-ci.yml` - Lint, unit test, generate manifests on push/PR to main
  - `.github/workflows/release.yml` - Publishes chart via chart-releaser on push to main

**CI Steps (helm-ci.yml):**
1. `actions/checkout@v6` - Checkout source
2. `azure/setup-helm@v4` (v3.19.0) - Install Helm CLI
3. `make lint-chart` - Lint all 16 test scenarios with `helm lint --strict`
4. `make unit-test` - Run helm-unittest via Docker (`helmunittest/helm-unittest:3.19.0-1.0.3`)
5. `make generate-templates` - Render all manifests
6. `actions/upload-artifact@v7` - Upload `generated-manifests/` as build artifact

**Release Steps (release.yml):**
1. Full checkout (`fetch-depth: 0`)
2. Git config for actor identity
3. `helm/chart-releaser-action@v1.7.0` with `skip_existing: true` and `CR_TOKEN: secrets.GITHUB_TOKEN`

## Environment Configuration

**Required env vars:**
- None for normal development or chart installation
- `CR_TOKEN` (= `secrets.GITHUB_TOKEN`) - Used only in release workflow, injected automatically by GitHub Actions

**Secrets location:**
- GitHub Actions repository secrets (only `GITHUB_TOKEN`, automatically provided)

## External Kubernetes Operators (cluster-side dependencies)

**External Secrets Operator:**
- Required when chart users configure `externalSecrets` values
- Chart generates `ExternalSecret` objects with `apiVersion: external-secrets.io/v1`
- Template: `charts/global-chart/templates/externalsecret.yaml`
- Must be pre-installed in target cluster; not bundled with this chart

**Ingress Controller:**
- Required when `ingress.enabled: true`
- Default `className: "nginx"` assumes nginx ingress controller
- Can be overridden via `ingress.className` in values

## Webhooks & Callbacks

**Incoming:**
- None

**Outgoing:**
- None

---

*Integration audit: 2026-03-17*
