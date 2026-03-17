# Architecture

**Analysis Date:** 2026-03-17

## Pattern Overview

**Overall:** Helm Chart Template Engine — a data-driven manifest generator where user-supplied `values.yaml` drives Kubernetes resource creation via Go templates.

**Key Characteristics:**
- No application runtime: all logic executes at Helm render time, not deployment time
- Multi-deployment architecture: a single chart release can produce N independent Deployments and their associated resources
- Composition via inheritance: hooks and cronJobs nested inside deployments inherit the parent's image, config, secrets, and service account
- Fail-fast validation: required fields and conflicting configurations are caught with `fail` calls during template rendering, not at runtime

## Layers

**Values Layer:**
- Purpose: Single source of truth for all configuration. Users express intent here.
- Location: `charts/global-chart/values.yaml`
- Contains: Default values with helm-docs annotations, schema documentation in comments
- Depends on: Nothing
- Used by: All templates during Helm render

**Helper Layer:**
- Purpose: Reusable named template functions shared across all resource templates
- Location: `charts/global-chart/templates/_helpers.tpl`
- Contains: Naming helpers, label builders, image resolution, shared renderers (`renderImagePullSecrets`, `renderDnsConfig`, `renderResources`, `renderVolume`, `imagePullPolicy`)
- Depends on: `.Values`, `.Release`, `.Chart` Helm objects
- Used by: All resource templates via `include "global-chart.<helperName>"`

**Resource Templates Layer:**
- Purpose: Generate Kubernetes manifests for each supported resource type
- Location: `charts/global-chart/templates/*.yaml` (all except `_helpers.tpl`)
- Contains: One template file per Kubernetes resource kind
- Depends on: Helper layer, values layer
- Used by: Helm renderer (`helm template`, `helm install`, `helm upgrade`)

**Test Layer:**
- Purpose: Validate template output correctness and lint scenario coverage
- Location: `charts/global-chart/tests/` (helm-unittest suites), `tests/` (lint value files)
- Contains: 16 test suites with 220 tests; 16 lint scenarios
- Depends on: Resource templates layer (reads rendered YAML output)
- Used by: CI pipeline and local `make unit-test` / `make lint-chart`

## Data Flow

**Deployment Resource Generation:**

1. User provides `deployments:` map in values (e.g., `deployments.frontend`, `deployments.backend`)
2. `deployment.yaml` iterates: `range $name, $deploy := .Values.deployments`
3. Each iteration calls `global-chart.deploymentEnabled` — skips if `enabled: false`
4. Helper `global-chart.deploymentFullname` constructs resource name: `{release}-{chart}-{deploymentName}` truncated to 63 chars
5. Image resolved via `global-chart.imageString` — handles string, map (`repository:tag`), digest, and global registry prefix injection
6. Dependent resources (Service, ConfigMap, Secret, ServiceAccount, HPA, PDB, NetworkPolicy) each iterate the same `deployments` map independently, applying the same `deploymentEnabled` guard

**Hook/CronJob Inheritance Flow (deployment-scoped):**

1. `deployment.yaml` renders the parent deployment
2. `cronjob.yaml` PART 2 iterates `deployments`, then iterates `$deploy.cronJobs` per deployment
3. Each nested job inherits: image, configMap, secret, serviceAccount, envFromConfigMaps, envFromSecrets, additionalEnvs, imagePullSecrets, hostAliases, podSecurityContext, securityContext, dnsConfig, nodeSelector, tolerations, affinity
4. Inheritance uses `hasKey` to distinguish "not provided" (inherit parent) from "provided as empty" (use empty, don't inherit): `ternary $job.field $deploy.field (hasKey $job "field")`
5. Hook templates are identical in pattern to CronJob templates

**Ingress Backend Resolution:**

1. `ingress.yaml` iterates `hosts` entries
2. For each host: checks `service.name` override first, then `deployment` reference, then fails
3. When using `deployment` reference: looks up `deployments[name]`, validates it exists and is enabled, derives service name from `deploymentFullname` helper and port from `deploy.service.port`

**Image Resolution Chain:**

1. `global-chart.imageString` accepts either new dict form `(dict "image" $img "global" $root.Values.global)` or legacy plain-value form
2. String images: checks first path segment for `.`, `:`, or `localhost` to detect existing registry; prepends `global.imageRegistry` if absent
3. Map images: same registry detection on `repository` field; assembles `repo:tag` or `repo@digest`
4. `fromDeployment` on root-level cronJobs/hooks copies the image value from the named deployment, then passes through the same resolution

**State Management:**
- No runtime state. All "state" is the rendered YAML committed to Kubernetes
- Config change detection uses `checksum/config` annotation on Deployment pod template, computed from `toYaml $deploy.configMap | sha256sum`, triggering rolling restarts

## Key Abstractions

**Deployment Unit:**
- Purpose: Represents one independently scalable application component
- Examples: `charts/global-chart/templates/deployment.yaml`, `charts/global-chart/templates/service.yaml`, `charts/global-chart/templates/hpa.yaml`
- Pattern: All deployment-scoped resources share the same `range $name, $deploy := .Values.deployments` iteration pattern with `deploymentEnabled` guard

**Shared Helpers:**
- Purpose: DRY rendering of common pod spec fragments
- Examples: `charts/global-chart/templates/_helpers.tpl` — `renderImagePullSecrets`, `renderDnsConfig`, `renderResources`, `renderVolume`
- Pattern: Return empty string when input is nil/empty, enabling `{{- with (include ...) }}...{{- end }}` wrappers to suppress blank lines

**Naming Convention:**
- Purpose: Deterministic, unique Kubernetes resource names scoped to release
- Examples: `global-chart.deploymentFullname`, `global-chart.hookfullname`
- Pattern: `{release}-{chart}-{deploymentName}` for deployment resources; CronJobs truncate to 52 chars to leave room for Kubernetes' 11-char Job timestamp suffix

**Label System:**
- Purpose: Pod selector uniqueness across multiple deployments in one release
- Examples: `global-chart.deploymentSelectorLabels`, `global-chart.deploymentLabels`
- Pattern: Selector labels include `app.kubernetes.io/component: {deploymentName}` so pods from different deployments don't match each other's selectors. Hook labels intentionally omit selector labels to prevent HPA from targeting hook jobs.

## Entry Points

**values.yaml:**
- Location: `charts/global-chart/values.yaml`
- Triggers: Read by Helm at render time, merged with user-supplied `-f values.yaml`
- Responsibilities: Provides defaults for all configurable fields; documents schema via helm-docs annotations

**deployment.yaml:**
- Location: `charts/global-chart/templates/deployment.yaml`
- Triggers: Rendered for every non-empty, enabled entry in `.Values.deployments`
- Responsibilities: Generates the core Deployment resource; other templates generate companion resources independently

**_helpers.tpl:**
- Location: `charts/global-chart/templates/_helpers.tpl`
- Triggers: `include "global-chart.<helper>"` calls in any template
- Responsibilities: All naming, labeling, image resolution, and shared pod-spec fragment rendering logic

## Error Handling

**Strategy:** Fail-fast at render time using Helm's `fail` function. Invalid configurations produce a descriptive error during `helm template` or `helm install` before any resources reach the cluster.

**Patterns:**
- Missing required fields: `required (printf "descriptive message" $name) $value` — used for image, schedule, remote.key, etc.
- Mutual exclusion: explicit `fail` with descriptive message, e.g., PDB `minAvailable`/`maxUnavailable` conflict
- Referential integrity: `fail` when `fromDeployment` or `ingress.deployment` references a non-existent deployment key
- Unknown enum values: `fail` with list of supported values, e.g., legacy volume `.type` unknown value
- Boolean default trap: `hasKey` + `ternary` instead of `default true` to correctly handle explicit `false` values

## Cross-Cutting Concerns

**Naming:** All resources use helpers in `_helpers.tpl` for consistent, DNS-safe names truncated to Kubernetes limits (63 chars for most, 52 for CronJobs).

**Labels:** `deploymentLabels` applied to all per-deployment resources; `labels` applied to release-scoped resources (Ingress, ExternalSecret, RBAC); hook labels intentionally minimal (no selector labels).

**Global Fallbacks:** `global.imageRegistry` and `global.imagePullSecrets` provide release-wide defaults; per-resource values override. The `hasKey` guard ensures explicit empty values (`imagePullSecrets: []`) block global inheritance rather than triggering it.

**Checksum Annotations:** Pod templates receive `checksum/config`, `checksum/secret`, and `checksum/mounted-config-files` annotations computed at render time, ensuring rolling restarts when referenced data changes.

---

*Architecture analysis: 2026-03-17*
