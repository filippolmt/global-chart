# Architecture

**Analysis Date:** 2026-03-15

## Pattern Overview

**Overall:** Single Helm chart with multi-resource generator pattern

**Key Characteristics:**
- Values-driven declarative configuration: all behavior controlled via `values.yaml` overrides; no imperative logic outside templates
- Multi-deployment fan-out: a single chart release generates N independent Deployment stacks (each with its own Service, SA, ConfigMap, Secret, HPA, PDB, NetworkPolicy)
- Two-level resource placement for Jobs/CronJobs: root-level (standalone) vs. deployment-scoped (inherits parent configuration)
- Shared rendering helpers encapsulate cross-cutting YAML blocks (imagePullSecrets, dnsConfig, resources, volumes) to avoid duplication

## Layers

**Values Layer:**
- Purpose: Consumer-supplied configuration input
- Location: `charts/global-chart/values.yaml` (defaults), user-supplied overlay files in `tests/`
- Contains: Default values with helm-docs annotations, commented examples for every supported field
- Depends on: Nothing
- Used by: All templates at render time

**Helper Layer:**
- Purpose: Named Go template functions shared across resource templates
- Location: `charts/global-chart/templates/_helpers.tpl`
- Contains: Naming helpers, label helpers, image resolution, volume rendering, imagePullSecrets/dnsConfig/resources rendering, ServiceAccount resolution
- Depends on: `.Chart`, `.Release`, `.Values.global`
- Used by: All resource templates

**Resource Template Layer:**
- Purpose: Generates Kubernetes manifests by iterating over values maps
- Location: `charts/global-chart/templates/*.yaml`
- Contains: One file per Kubernetes resource type; each file may emit multiple documents
- Depends on: Helper layer, values layer
- Used by: Helm CLI at install/upgrade/template time

**Test Layer:**
- Purpose: Validates rendering correctness
- Location: `charts/global-chart/tests/*_test.yaml` (helm-unittest), `tests/*.yaml` (lint value fixtures)
- Contains: 16 helm-unittest suites (220 tests), 16 lint scenario value files
- Depends on: Resource template layer

## Data Flow

**Standard Deployment Rendering:**

1. User provides values overlay (e.g. `tests/multi-deployment.yaml`)
2. Helm merges overlay with `charts/global-chart/values.yaml` defaults
3. `deployment.yaml` iterates `range $name, $deploy := .Values.deployments`
4. For each enabled deployment, calls `global-chart.deploymentFullname` and `global-chart.deploymentLabels` helpers
5. Emits one `---`-separated Deployment document per deployment entry
6. Sibling templates (`service.yaml`, `serviceaccount.yaml`, `configmap.yaml`, `secret.yaml`, `hpa.yaml`, `pdb.yaml`, `networkpolicy.yaml`, `mounted-configmap.yaml`) independently iterate the same `deployments` map and emit their documents

**Hooks/CronJobs Inheritance Flow:**

1. Root-level: `hooks:` / `cronJobs:` maps iterated standalone; image sourced from explicit `image:` or via `fromDeployment:` reference
2. Deployment-scoped: `deployments.<name>.hooks` / `deployments.<name>.cronJobs` iterated inside a `range` over `deployments`; image, configMap, secret, SA, envFromConfigMaps, envFromSecrets, additionalEnvs, imagePullSecrets, hostAliases, podSecurityContext, securityContext, nodeSelector, tolerations, affinity inherited with `hasKey`-guarded override semantics (explicit value in job wins)
3. Override chain for each inheritable field: `hasKey $job "field" | ternary $job.field $deploy.field`

**Ingress Routing Flow:**

1. Single `Ingress` resource emitted (named `{release}-{chart}`, no deployment suffix)
2. Each host entry in `ingress.hosts` resolves backend service: explicit `service.name` > `deployment` reference (looks up `deployments.<name>` and derives service name via `global-chart.deploymentFullname`) > template `fail`
3. Disabled deployments referenced by ingress produce a compile-time `fail` with clear error

**Image Resolution Flow:**

1. `global-chart.imageString` called with `(dict "image" $value "global" $root.Values.global)`
2. If image is a string: check if first path segment looks like a registry (contains `.` or `:` or equals `localhost`); if not, prepend `global.imageRegistry`
3. If image is a map: build `repository[:tag]` or `repository@digest`; apply same registry detection to `repository`
4. `global-chart.imagePullPolicy` resolves pull policy with priority: override > image.pullPolicy > fallback > `IfNotPresent`

**Global Fallback Chain (imagePullSecrets):**

1. At each resource (Deployment, CronJob, Hook): check `hasKey $resource "imagePullSecrets"`
2. If set (even as `[]`): use that value — empty list is intentional, stops fallback
3. If not set: fall back to `$root.Values.global.imagePullSecrets`

## Key Abstractions

**Deployment Entry (`deployments.<name>`):**
- Purpose: Represents one independently named workload with its full resource stack
- Examples: `tests/multi-deployment.yaml` (frontend, backend, worker, minimal entries)
- Pattern: Map key becomes the `component` label and the name suffix for all child resources

**Deployment-scoped Job (`deployments.<name>.hooks`, `deployments.<name>.cronJobs`):**
- Purpose: Job/CronJob that shares image and config with its parent deployment
- Examples: `tests/deployment-hooks-cronjobs.yaml`
- Pattern: `hasKey`-guarded inheritance; hook/job values take precedence when key is present

**Shared Render Helpers:**
- Purpose: Emit reusable YAML blocks that may return empty string (used with `{{- with }}`)
- Examples: `global-chart.renderImagePullSecrets`, `global-chart.renderDnsConfig`, `global-chart.renderResources`, `global-chart.renderVolume`
- Pattern: Caller wraps result with `{{- with (include "...") }}{{- . | nindent N }}{{- end }}`; helpers use `-}}` trim on conditional lines to avoid leading newlines

**ServiceAccount Resolution (`global-chart.deploymentServiceAccountName`):**
- Purpose: Uniform SA name resolution across Deployment, Hook, CronJob
- Examples: `charts/global-chart/templates/_helpers.tpl` lines 96-107
- Pattern: `hasKey`-based check on `serviceAccount.create`; defaults to `true` when key absent

## Entry Points

**Helm Install/Upgrade:**
- Location: All files in `charts/global-chart/templates/` (excluding `_helpers.tpl`)
- Triggers: `helm install`, `helm upgrade`, `helm template`
- Responsibilities: Each template file iterates its relevant values key and emits zero or more YAML documents

**NOTES.txt:**
- Location: `charts/global-chart/templates/NOTES.txt`
- Triggers: Post-install/upgrade Helm display
- Responsibilities: Prints per-deployment service summaries and access instructions

**Helm Test:**
- Location: `charts/global-chart/templates/tests/test-connection.yaml`
- Triggers: `helm test <release>`
- Responsibilities: Emits a Pod that curl-tests the first enabled service

## Error Handling

**Strategy:** Compile-time `fail` for configuration mistakes; no runtime error handling (Helm chart, not application code)

**Patterns:**
- Missing required fields: `{{ required "message" $value }}` causes `helm template`/`helm install` to abort with a clear message
- Invalid configurations: `{{- fail "message" }}` inside conditionals (e.g., PDB with both minAvailable and maxUnavailable set, NetworkPolicy with no rules, unknown volume `.type`)
- Cross-reference validation: ingress referencing non-existent or disabled deployment causes `fail` with deployment name in message
- Image validation: map image without `tag` or `digest` causes `fail`; root-level job without image or `fromDeployment` causes `fail`

## Cross-Cutting Concerns

**Naming/Truncation:** All resource names truncated to 63 chars (`trunc 63 | trimSuffix "-"`); CronJob names truncated to 52 chars to allow Kubernetes' 11-char Job suffix. Enforced in helpers and inline in template files.

**Label Consistency:** Non-deployment resources use `global-chart.labels` / `global-chart.selectorLabels` (no `component`). Per-deployment resources use `global-chart.deploymentLabels` / `global-chart.deploymentSelectorLabels` (adds `app.kubernetes.io/component: <deploymentName>`). Hook resources deliberately omit selector labels to avoid HPA matching.

**Boolean Defaults:** Fields that default to `true` (e.g., `serviceAccount.create`, `deployment.enabled`) use `hasKey` + `ternary` pattern rather than `default true $var`, because Go templates treat `false` as falsy and would incorrectly replace it with the default. Pattern: `ternary $map.field true (hasKey $map "field")`.

**Immutability of .Values:** Templates never mutate `.Values` or nested maps. Local copies made with `deepCopy` before modification (e.g., `ingress.yaml` line 5 deepCopies annotations before use).

---

*Architecture analysis: 2026-03-15*
