# Stack Research: Helm Chart Audit & Hardening Tools

**Domain:** Helm chart quality, security, and validation tooling
**Researched:** 2026-03-15
**Confidence:** MEDIUM-HIGH (versions verified via WebSearch; some exact version numbers from GitHub releases pages)

## Current Stack (Already In Use)

These are confirmed in `.planning/codebase/STACK.md` and `Makefile`. Do NOT re-add them; this section exists only to show what is covered and identify gaps.

| Tool | Version | What It Covers |
|------|---------|----------------|
| helm lint --strict | Helm v3.19.0 | YAML syntax, template rendering errors |
| helm-unittest | 3.19.0-1.0.3 | Template logic assertions (220 tests) |
| kube-linter | latest-alpine (v0.8.1) | K8s best practices on rendered manifests |
| helm-docs | jnorwood/helm-docs:latest | README generation from value annotations |

**Gap analysis:** The current stack covers linting, unit testing, best-practice checks, and docs generation. Missing layers are: **Kubernetes schema validation** (are rendered manifests valid K8s?), **security policy scanning** (CIS/NSA/MITRE compliance), **values input validation** (JSON Schema), and **chart-level integration testing** (install/upgrade on real clusters).

---

## Recommended Additions

### Tier 1: High-Value, Add Now

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| kubeconform | v0.7.0 | Validate rendered manifests against K8s OpenAPI schemas | kube-linter checks best practices but does NOT validate that a manifest is structurally valid Kubernetes. kubeconform catches typos in apiVersion, kind, field names, and schema violations. It is the de facto successor to kubeval (deprecated). Extremely fast (Go, parallel). | HIGH |
| values.schema.json | Helm built-in | Validate user-supplied values at `helm install/upgrade/template` time | Helm natively supports JSON Schema validation. Without it, invalid values silently produce broken manifests. This is the single highest-impact hardening step for a reusable chart. | HIGH |
| helm-values-schema-json | v1.7.2 | Generate values.schema.json from annotated values.yaml | Writing JSON Schema by hand for a complex chart is error-prone. This Helm plugin generates it from comments in values.yaml, keeping schema and values in sync. | MEDIUM |

### Tier 2: Valuable, Add During Hardening Phase

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| Trivy | v0.69.3 | Security misconfiguration scanning (150+ checks) | Complements kube-linter with security-focused checks: privilege escalation, capabilities, seccomp profiles, image source trust. Templates the chart with default values and scans rendered manifests. Widely adopted (Aqua Security, CNCF). | HIGH |
| Polaris | v10.1.1 | Best-practice audit with scoring | Provides a numeric score and actionable pass/fail per check. `polaris audit --helm-chart ./charts/global-chart --helm-values <file>` directly audits a chart. Good for generating a hardening report card. Overlaps partially with kube-linter but has different check set (health probes, resource requests, security). | MEDIUM |
| chart-testing (ct) | v3.14.0 | Lint + install/upgrade testing against a real cluster | The official Helm project tool for CI. Detects changed charts, runs `helm lint`, installs on a cluster, runs `helm test`, and tests upgrade from previous version. Essential for validating install/upgrade lifecycle. | MEDIUM |

### Tier 3: Nice-to-Have, Consider Later

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| Kubescape | v3.x (CLI) | NSA/CISA + MITRE ATT&CK framework compliance | Scans against multiple security frameworks simultaneously. Useful if the chart targets regulated environments. Heavier than Trivy for pure chart scanning. | LOW |
| Checkov | v3.x | IaC security scanner (Bridgecrew/Prisma Cloud) | 150+ Kubernetes checks, auto-detects Chart.yaml. Already enabled in the project's `coderabbit.yaml` for PR reviews. Running it locally/in CI adds defense-in-depth but overlaps significantly with Trivy + kube-linter. | LOW |

---

## Installation & Integration

### kubeconform

```bash
# Install (macOS)
brew install kubeconform

# Or use Docker (no local install needed, consistent with project pattern)
# Add to Makefile:
KUBECONFORM_IMAGE := ghcr.io/yannh/kubeconform:v0.7.0

# Usage: validate generated manifests
helm template test ./charts/global-chart -f tests/test01/values.01.yaml | \
  kubeconform -strict -summary -kubernetes-version 1.29.0

# For CRDs (ExternalSecret), add schema source:
kubeconform -strict -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -kubernetes-version 1.29.0
```

**Makefile target pattern:**
```makefile
kubeconform: generate-templates  ## Validate manifests against K8s schemas
	@echo "==> Running kubeconform..."
	@find $(GENERATED_DIR) -name '*.yaml' | xargs kubeconform \
		-strict -summary -kubernetes-version 1.29.0 \
		-schema-location default \
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

### values.schema.json

```bash
# Install the generator plugin
helm plugin install https://github.com/losisin/helm-values-schema-json.git

# Generate schema from annotated values.yaml
cd charts/global-chart
helm schema -input values.yaml -output values.schema.json

# Validation happens automatically on:
#   helm install, helm upgrade, helm template
# No additional CI step needed -- Helm enforces it natively.
```

### Trivy

```bash
# Install (macOS)
brew install trivy

# Scan the chart directory (auto-detects Chart.yaml)
trivy config ./charts/global-chart --severity HIGH,CRITICAL

# Or template first for more control:
helm template test ./charts/global-chart -f tests/test01/values.01.yaml > /tmp/rendered.yaml
trivy config /tmp/rendered.yaml --severity HIGH,CRITICAL
```

### Polaris

```bash
# Install (macOS)
brew tap FairwindsOps/tap && brew install FairwindsOps/tap/polaris

# Audit the chart
polaris audit --helm-chart ./charts/global-chart \
  --helm-values tests/test01/values.01.yaml \
  --format pretty

# CI: use --format score and set threshold
polaris audit --helm-chart ./charts/global-chart \
  --helm-values tests/test01/values.01.yaml \
  --format score --set-exit-code-below-score 80
```

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| kubeconform | kubeval | Never. kubeval is deprecated and unmaintained. kubeconform is its direct replacement. |
| kubeconform | Datree | Never for OSS. Datree shut down its SaaS in 2023. The CRD schema catalog lives on and is useful with kubeconform. |
| Trivy | Checkov | When your org standardizes on Prisma Cloud/Bridgecrew. For standalone Helm chart work, Trivy is lighter and more focused. |
| Trivy | Snyk IaC | When your org has a Snyk license. Snyk provides good Helm support but is commercial. |
| Polaris | Kubescape | When you need multi-framework compliance (NSA, MITRE, CIS). Polaris is simpler for pure best-practice scoring. |
| helm-values-schema-json | helm-schema (dadav) | Both are viable. helm-values-schema-json is more mature and has a GitHub Action. dadav/helm-schema uses Go struct-like annotations. Either works. |
| helm-values-schema-json | Manual JSON Schema | When your chart has complex conditional validation (oneOf, if/then). The generator handles 90% of cases; hand-tune the remaining 10%. |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| kubeval | Deprecated since 2022, no longer updated with new K8s schemas | kubeconform |
| Datree (SaaS) | Company shut down, product EOL | kubeconform + Trivy |
| helm-schema-gen (karuppiah7890) | Unmaintained (README says "CURRENTLY NOT MAINTAINED") | helm-values-schema-json (losisin) |
| conftest/OPA for basic checks | Overkill for chart-level auditing. Requires writing Rego policies from scratch. | kube-linter + Polaris (pre-built checks) |
| Custom shell scripts for validation | Fragile, not portable, no schema awareness | kubeconform + values.schema.json |

---

## Recommended CI Pipeline Order

The tools layer on top of each other in a specific order. Each catches different classes of issues:

```
1. helm lint --strict          (syntax + template rendering)
2. helm-unittest               (template logic assertions)
3. values.schema.json          (enforced by helm template/install automatically)
4. kubeconform                 (rendered manifests are valid K8s)
5. kube-linter                 (K8s best practices)
6. trivy config                (security misconfigurations)
7. polaris audit --format score (best-practice scoring, optional gate)
```

Steps 1-5 should be in CI for every PR. Steps 6-7 are recommended but can be advisory (non-blocking) initially.

---

## Version Compatibility

| Tool | Compatible With | Notes |
|------|-----------------|-------|
| kubeconform v0.7.0 | K8s 1.19-1.31 schemas | Specify target version with `-kubernetes-version`. Uses upstream OpenAPI schemas. |
| helm-unittest 1.0.3 | Helm 3.19.0 | Image tag encodes the Helm version: `3.19.0-1.0.3`. Must match local Helm. |
| kube-linter v0.8.1 | K8s 1.x manifests | Version-agnostic; checks patterns, not schema. |
| Trivy v0.69.3 | Helm v3 charts | Auto-detects Chart.yaml. Templates internally. |
| Polaris v10.1.1 | Helm v3 charts | Uses `--helm-chart` flag to template and audit. |
| chart-testing v3.14.0 | Helm v3, requires cluster | Needs kind/k3d for CI. Not needed for this project's current scope. |

---

## Sources

- [kubeconform GitHub](https://github.com/yannh/kubeconform) -- v0.7.0 confirmed, MEDIUM confidence on exact release date
- [Trivy Helm coverage](https://trivy.dev/docs/latest/coverage/iac/helm/) -- v0.69.3 confirmed via Chocolatey and GitHub releases
- [Polaris GitHub](https://github.com/FairwindsOps/polaris) -- v10.1.1 confirmed via GitHub releases page
- [Polaris IaC docs](https://polaris.docs.fairwinds.com/infrastructure-as-code/) -- helm-chart flag verified
- [kube-linter releases](https://github.com/stackrox/kube-linter/releases) -- v0.8.1 confirmed
- [helm-values-schema-json GitHub](https://github.com/losisin/helm-values-schema-json) -- v1.7.2 from pre-commit config reference
- [chart-testing GitHub](https://github.com/helm/chart-testing) -- v3.14.0 from Docker/releases
- [Helm JSON Schema validation](https://www.arthurkoziel.com/validate-helm-chart-values-with-json-schemas/) -- native Helm feature, HIGH confidence
- [Checkov Helm scanning](https://www.checkov.io/7.Scan%20Examples/Helm.html) -- confirmed auto-detection via Chart.yaml
- [Kubescape GitHub](https://github.com/kubescape/kubescape) -- CLI scan capability confirmed

---
*Stack research for: Helm chart audit & hardening tools*
*Researched: 2026-03-15*
