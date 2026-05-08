# Changelog

All notable changes to this chart are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versioning follows [Semantic Versioning](https://semver.org/).

---

## [1.7.0] — 2026-05-31

### Added
- HTTPRoute template (`templates/httproute.yaml`) supporting Gateway API v1
- Top-level `.Values.httpRoute` block: `parentRefs`, `hostnames`, `rules` (matches/filters/backendRefs/timeouts)
- Filter types: `RequestRedirect`, `URLRewrite`, `RequestHeaderModifier`, `ResponseHeaderModifier`, `RequestMirror`, `ExtensionRef`
- Multi-backend weighted routing for canary deployments
- Shared backend resolution helper `global-chart.resolveBackend` (used by both Ingress and HTTPRoute)
- kubeconform validation extended to `gateway.networking.k8s.io` schemas via `datreeio/CRDs-catalog`
- 4 lint scenarios: `tests/httproute-basic.yaml`, `tests/httproute-canary.yaml`, `tests/httproute-filters.yaml`, `tests/bad-values/httproute-conflict.yaml`
- 2 helm-unittest suites: `httproute_test.yaml` (rendering), `httproute_validation_test.yaml` (failure cases)

### Changed
- `templates/ingress.yaml` backend resolution refactored to call `global-chart.resolveBackend` (behavior-preserving — all existing tests pass unchanged)

### Notes
- Gateway API v1 CRDs MUST be installed in the cluster; the chart does not create the Gateway resource (platform-managed)
- `.Values.ingress.enabled: true` and `.Values.httpRoute.enabled: true` are mutually exclusive — enabling both fails template render

### Migration: Ingress → HTTPRoute

| Ingress field                          | HTTPRoute equivalent                               | Notes                                          |
|----------------------------------------|-----------------------------------------------------|------------------------------------------------|
| `ingress.className`                    | `httpRoute.parentRefs[].name` (Gateway name)       | Gateway is platform-managed, not chart-rendered |
| `ingress.tls[].secretName`             | Configured on the Gateway listener (out of chart scope) | Use `parentRefs[].sectionName` to bind HTTPS listener |
| `ingress.hosts[].host`                 | `httpRoute.hostnames[]`                            | Multiple hostnames per HTTPRoute supported      |
| `ingress.hosts[].paths[].path`         | `httpRoute.rules[].matches[].path.value`           |                                                |
| `ingress.hosts[].paths[].pathType`     | `httpRoute.rules[].matches[].path.type`            | `Prefix` → `PathPrefix`; `Exact` → `Exact`     |
| `ingress.hosts[].deployment`           | `httpRoute.rules[].backendRefs[].deployment`       | Same resolution semantics                       |
| `ingress.hosts[].service.{name,port}`  | `httpRoute.rules[].backendRefs[].service.{name,port}` | Same                                         |
| nginx-ingress canary annotations       | `httpRoute.rules[].backendRefs[].weight`           | Native traffic split                            |
| nginx `rewrite-target` annotation      | `httpRoute.rules[].filters[].URLRewrite`           | Native filter                                   |
| nginx `permanent-redirect` annotation  | `httpRoute.rules[].filters[].RequestRedirect`      | Native filter                                   |

---

## [1.6.2] — 2026-05-31

### Changed

#### Internal: resource-name helper consolidation

Pure refactor — rendered manifests are byte-identical. The `printf | trunc` naming rules that were duplicated inline between the resource templates and the collision validator now live in five helpers in `_helpers.tpl`, each the single home for its name (and its truncation constant):

- **`global-chart.rootCronJobName`** / **`global-chart.deploymentCronJobName`** — CronJob names (trunc 52).
- **`global-chart.deploymentHookName`** — deployment-level hook Job name (single trunc 63 over the full 4-part name).
- **`global-chart.hookPrereqConfigName`** / **`global-chart.hookPrereqSecretName`** — hook-prerequisite ConfigMap/Secret names (trunc 63).

`cronjob.yaml`, `hook.yaml` and `_validate-helpers.tpl` all call these helpers, so the collision validator can no longer drift from the names the templates emit.

As part of this, `validateNameCollisions` previously computed the deployment-level hook Job name by truncating `deploymentFullname` first and re-truncating after appending `-<hookType>-<jobName>`, whereas `hook.yaml` truncates the full 4-part name once. The two forms only ever differ at a trailing-dash truncation boundary — i.e. for names Kubernetes itself would reject — so the collision **verdict** was never wrong for any valid input; the divergence was a latent inconsistency, not an observable bug. Routing both sites through `deploymentHookName` removes it.

---

## [1.6.1] — 2026-05-31

### Changed

#### Internal: job helper deduplication (issues #54, #55)

Pure refactor — rendered manifests are byte-identical; error messages unchanged.

- **`global-chart.jobImageString`** (`_job-helpers.tpl`): unifies the image-resolution choice (`explicit image > deploy.image > fromDeployment lookup+fail`) previously duplicated across four inline blocks in `cronjob.yaml` and `hook.yaml` (root + deployment-level). The `errCtx` argument preserves the exact `fromDeployment` failure messages.
- **`global-chart.jobServiceAccount`** (`_job-helpers.tpl`): unifies the deployment-level ServiceAccount resolution (name/create/automount/annotations) previously duplicated near-verbatim across `hook.yaml` PART 2 and `cronjob.yaml` PART 2. Returns a JSON object consumed via `fromJson`.
- Removed a dead `serviceAccount.automountServiceAccountToken` branch in the hook SA logic — the key is rejected by `values.schema.json` (`additionalProperties: false`), so it was unreachable. Automount is controlled by the job-level `automountServiceAccountToken` and the SA-map `automount` keys, unchanged.

Follow-ups resolved: #56 (`deploymentMetadata` helper) closed as won't-do; #57 (`renderJob` collapse) recorded as a deliberate non-decision in [ADR-0001](docs/adr/0001-keep-root-and-deployment-job-rendering-separate.md).

---

## [1.6.0] — 2026-05-21

### Added

#### Multi-port Services (issue #52)

- **`service.extraPorts`**: list of additional ports rendered on the same Service after the primary port. Unblocks workloads needing multiple ports on the same Pod selector (Odoo HTTP+gevent, Redis client+TLS, gRPC sidecars, exporters).
- Schema enforces required `[name, port, targetPort]` per item with `additionalProperties: false`. Optional: `protocol` (TCP/UDP/SCTP, default TCP), `appProtocol`, `nodePort` (30000-32767).

```yaml
deployments:
  odoo:
    service:
      port: 8069
      targetPort: 8069
      portName: odoo
      extraPorts:
        - name: gevent
          port: 8072
          targetPort: 8072
          appProtocol: http
        - name: metrics
          port: 9090
          targetPort: metrics
```

### Compatibility

- Backward compatible: Services without `extraPorts` render byte-for-byte identical manifests.

---

## [1.5.0] — 2026-05-08

### Added

#### CronJob hardening (issue #48)

- **CronJob spec fields**: `timeZone` (k8s ≥1.27), `suspend`, `startingDeadlineSeconds`.
- **jobTemplate.spec fields**: `backoffLimit`, `ttlSecondsAfterFinished`, `activeDeadlineSeconds`, `parallelism`, `completions`.
- Applied to both root-level (`.Values.cronJobs`) and deployment-level (`.Values.deployments.<name>.cronJobs`) cronJobs.

```yaml
cronJobs:
  cleanup:
    schedule: "0 2 * * *"
    timeZone: "Europe/Rome"
    backoffLimit: 3
    ttlSecondsAfterFinished: 600     # GC finished Jobs (avoids etcd bloat)
    activeDeadlineSeconds: 900       # kill runaway Jobs
    suspend: false
```

#### Deployment graceful shutdown (issue erredi #6)

- **Container `lifecycle`** (preStop / postStart) on deployments.
- **Pod `terminationGracePeriodSeconds`** on deployments.

```yaml
deployments:
  fast-api:
    image: myapp:v1
    terminationGracePeriodSeconds: 30
    lifecycle:
      preStop:
        exec:
          command: ["/bin/sh", "-c", "sleep 5"]
```

#### Inheritance opt-out toggles

- `inheritDeploymentSecret: false` and `inheritDeploymentConfigMap: false` on deployment-level cronjobs/hooks. Defaults `true`. Allows narrow-scope cronjobs to break envFrom inheritance, limiting secret leak surface.

```yaml
deployments:
  fast-api:
    secret:
      DB_PASSWORD: "..."
      MAILJET_KEY: "..."
    cronJobs:
      narrow-scope-job:
        schedule: "*/10 * * * *"
        inheritDeploymentSecret: false
        envFromSecrets: ["only-this-token"]
```

### Fixed

- **Empty `metadata:` blocks in CronJob output (issue #48)**. `jobTemplate.metadata` and `jobTemplate.spec.template.metadata` are now wrapped in conditional rendering. Previously emitted bare `metadata:` keys when `commonAnnotations` was empty, flagged by strict linters (kubeval, polaris).

### Changed

- **Schema validation tightened**: `cronJob.completions` and `deploymentCronJob.completions` now require `minimum: 1` (was `0`). Kubernetes Jobs reject `completions: 0` at apply time; schema now catches this earlier.

### Documentation

- `CLAUDE.md`: clarify root-vs-deployment-level cronJob/hook inheritance asymmetry; document new opt-out toggles.
- `values.yaml`: commented hardening examples on both cronJob locations.

### Migration

No breaking changes. All new fields are opt-in. Upgrade is a drop-in replacement for 1.4.x.

---

## [1.4.0] — 2026-03-17

### Migration guide from 1.3.x

> **This release contains behavioral breaking changes.** Read the migration guide carefully before running `helm upgrade`.

#### 1. Hook/CronJob SA inheritance now defaults to `create: true` (HIGH)

Deployment-level hooks and cronjobs now inherit the deployment's ServiceAccount by default. Previously, if the deployment didn't have an explicit `serviceAccount` block, hooks/cronjobs created their own SA.

**Who is affected:** all deployment-level hooks/cronjobs where the parent deployment does not explicitly set `serviceAccount.create`.

**Impact:** the hook/cronjob now runs with the deployment's SA. If RBAC differs, permissions may change.

**Action:** to preserve old behavior, explicitly set `serviceAccountName` on the hook/cronjob:

```yaml
deployments:
  backend:
    image: myapp:v2
    hooks:
      pre-upgrade:
        migrate:
          command: ["./migrate.sh"]
          serviceAccountName: "my-custom-sa"  # Override inheritance
```

#### 2. Legacy volume key precedence flipped (HIGH — edge case)

For legacy-format volumes, `secret.secretName` (the canonical Kubernetes key) now takes priority over the non-standard `secret.name` alias when both are present. Same for `persistentVolumeClaim.claimName` vs `.name`.

**Who is affected:** only users specifying BOTH `secret.name` and `secret.secretName` with different values (extremely rare).

**Action:** use only the canonical key (`secretName` / `claimName`). Remove the `name` alias if present:

```yaml
# Before (ambiguous — which one wins?)
volumes:
  - name: creds
    type: secret
    secret:
      name: old-secret         # Remove this
      secretName: new-secret   # Keep this (now wins)

# After (unambiguous)
volumes:
  - name: creds
    type: secret
    secret:
      secretName: new-secret
```

#### 3. Hook weight calculation changed (MEDIUM)

Hook SA weight is now computed as `jobWeight - 5` (was hardcoded `"5"`). Prerequisite ConfigMap/Secret weight is `minJobWeight - 7` (was hardcoded `"3"`).

For the default case (weight=10): SA=5, prereq=3 — **no change**. Only differs with custom `weight` overrides.

**Who is affected:** users with custom `weight` on hooks.

**Action:** run `helm template` and verify hook execution order after upgrade.

#### 4. `values.schema.json` added (CONDITIONAL)

A JSON Schema Draft 7 is now included. Helm uses it to validate values during `helm install/upgrade/lint`. Values with unknown top-level keys or incorrect types will be rejected.

**Who is affected:** users with non-standard top-level keys in values or values with incorrect types.

**Action:** run `helm lint` with your values before upgrading to see if schema validation catches anything. Fix any reported issues.

#### Migration checklist

- [ ] Read the points above and verify applicability
- [ ] Audit RBAC for deployment-level hooks/cronjobs (point 1)
- [ ] Check legacy volume specs for dual `name`/`secretName` usage (point 2)
- [ ] If using custom hook weights, verify execution order (point 3)
- [ ] Run `helm lint -f your-values.yaml` to test schema validation (point 4)
- [ ] Run `helm diff upgrade` to inspect all differences before applying
- [ ] Schedule the upgrade during a maintenance window
- [ ] Run `helm upgrade`

---

### Added

- **global.commonLabels** — opt-in shared labels applied to all resource metadata via the labels helper
- **global.commonAnnotations** — opt-in shared annotations applied to all resource metadata
- **Service annotations** — per-service `service.annotations` merged with `global.commonAnnotations` (service-specific wins on conflict)
- **JSON Schema Draft 7** — `values.schema.json` for input validation and IDE autocomplete
- **Name collision detection** — `validate.yaml` + `_validate-helpers.tpl` fail fast when truncation creates duplicate resource names
- **Ingress validation** — template fails with clear error when ingress host references a disabled deployment or a deployment with `service.enabled: false`
- **kubeconform** — CI step validates all generated manifests against K8s 1.29 schema
- **kube-linter** — CI step with `addAllBuiltIn: true` and documented exclusions
- **Bad-values validation** — CI step verifying schema correctly rejects invalid values
- **Docker pre-pull** — CI pre-pulls Docker images with 3 retries for resilience
- 90+ new unit tests (312 total across 17 suites), including negative `failedTemplate` tests

### Changed

- **Helper decomposition** — `_helpers.tpl` split into `_image-helpers.tpl`, `_job-helpers.tpl`, `_render-helpers.tpl`, `_validate-helpers.tpl` (~260 lines deduplication)
- **`inheritedJobPodSpec` shared helper** — eliminates duplication between deployment-level hook and cronjob pod spec rendering
- **Hook SA weight** — derived from Job weight (`jobWeight - 5`, min 0) instead of hardcoded "5"
- **Hook prerequisite weight** — derived from min Job weight (`minJobWeight - 7`, min 0) instead of hardcoded "3"
- **SA inheritance** — `deploySA.create` defaults to `true` via `hasKey/ternary`, matching `serviceaccount.yaml` behavior
- **Image tag/digest** — `toString` before `trim` to safely handle numeric tags (e.g., `tag: 1.25`)
- **Legacy volume precedence** — canonical K8s keys (`secretName`, `claimName`) now take priority over non-standard aliases (`name`)
- **Service annotations** — `deepCopy` before `merge` to avoid mutating `.Values`
- **restartPolicy** — null-safe with `default "Never"` fallback for empty/null values
- **renderVolume** — `required` guard on volume `name` field for clear error messages
- **Makefile** — `$(pwd)` → `$(CURDIR)` for consistency; new `validate-bad-values` target

### Fixed

- **CronJob SA null** — `serviceAccountName: null` now correctly falls back to job fullname
- **Schema completeness** — added `metadataPolicy`, `target.name`, `volumeMounts`, `initContainers`, `serviceAccountAnnotations`, `env`, `claims`, `mountPath`, `mountedConfigFiles` items schemas, `ingress.tls` items schema
- **Schema accuracy** — removed phantom `podAnnotations` and `suspend` from job definitions; removed dead `additionalEnvs` from root-level job definitions; `imagePullSecrets` accepts both strings and objects; `resources` allows custom types (GPU, ephemeral-storage)

---

## [1.3.0] — 2026-03-13

### Migration guide from 1.2.x

> **This release contains no blocking breaking changes**, but includes behavioral changes that may cause pod restarts or rendering differences. Read carefully before running `helm upgrade`.

#### 1. Expected rolling restart on first upgrade

The upgrade adds new annotations and labels to pod templates, which Kubernetes interprets as a spec change → rolling restart:

| Change | Effect |
|--------|--------|
| Added `checksum/secret` in pod annotations | Deployment pods are recreated on first upgrade |
| Added `app.kubernetes.io/version` label on all resources | Metadata labels change (not selectors, no impact on existing ReplicaSets) |

**Action:** schedule the upgrade during a maintenance window. After the first upgrade, subsequent restarts only happen when configMap/secret/mountedConfigFiles actually change.

#### 2. CronJob/Hook inheritance fix (potential behavior change)

Previous versions had a bug: explicitly setting an empty field (`nodeSelector: {}`, `tolerations: []`, `affinity: {}`, `imagePullSecrets: []`) on a deployment-level CronJob or Hook **did not override** the parent deployment value — it inherited it anyway.

This is now fixed: an explicit empty value **overrides** inheritance.

**Who is affected:** only users who explicitly set empty fields on deployment-level CronJob/Hook while the parent deployment has those fields populated. If you don't use hooks/cronJobs inside deployments, there is no impact.

**Action:** review your values for deployment-level CronJob/Hook. If you relied on the buggy behavior (empty field still inheriting from parent), remove the field to preserve inheritance.

```yaml
# Before (1.2.x) — empty nodeSelector inherited from deployment (bug)
deployments:
  backend:
    nodeSelector:
      disktype: ssd
    cronJobs:
      cleanup:
        nodeSelector: {}  # Bug: inherited disktype: ssd

# After (1.3.0) — empty nodeSelector correctly overrides
deployments:
  backend:
    nodeSelector:
      disktype: ssd
    cronJobs:
      cleanup:
        nodeSelector: {}  # Correct: no nodeSelector
        # To inherit: remove the nodeSelector line entirely
```

#### 3. Default resources for CronJob/Hook are now configurable

Default resources (100m CPU, 128Mi memory) for CronJobs and Hooks are **no longer hardcoded** in templates. They are read from `defaults.resources` in values.yaml.

The default value in values.yaml is identical to the previous hardcoded value, so **no change unless you override `defaults`**. If you override `defaults: {}` without specifying `resources`, CronJobs/Hooks without explicit resources will have no resource requests.

**Action:** none, unless you completely override the `defaults` section.

#### 4. Volumes: native Kubernetes support (no change required)

Volumes now accept both native Kubernetes spec and the legacy `.type` format. The legacy format continues to work without modifications.

```yaml
# Legacy format (still works)
volumes:
  - name: data
    type: emptyDir

# Native format (new, recommended)
volumes:
  - name: data
    emptyDir: {}
  - name: certs
    csi:
      driver: secrets-store.csi.k8s.io
```

**Action:** no migration required. Gradually adopting the native format for new volumes is recommended.

#### 5. Global values (optional, no change required)

New `global` section in values.yaml to share `imageRegistry` and `imagePullSecrets` across all resources. Completely opt-in.

**Action:** none. To centralize registry or pull secrets, add:

```yaml
global:
  imageRegistry: registry.example.com
  imagePullSecrets:
    - name: my-regcred
```

#### Migration checklist

- [ ] Read the points above and verify applicability
- [ ] Verify that deployment-level CronJob/Hook do not depend on the inheritance bug (point 2)
- [ ] Schedule the upgrade during a maintenance window (point 1)
- [ ] Run `helm diff upgrade` to inspect differences before applying
- [ ] Run `helm upgrade`
- [ ] Verify that pods restart correctly

---

### Added

- **PodDisruptionBudget** — new `pdb.yaml` template, enable per deployment with `pdb.enabled: true` and `minAvailable`/`maxUnavailable`
- **NetworkPolicy** — new `networkpolicy.yaml` template, enable per deployment with `networkPolicy.enabled: true` and ingress/egress rules
- **Helm test** — `helm test <release>` verifies connectivity to the first enabled service (`templates/tests/test-connection.yaml`)
- **Deployment strategy** — configurable `strategy` (RollingUpdate/Recreate) per deployment
- **revisionHistoryLimit** — optional field per deployment
- **progressDeadlineSeconds** — optional field per deployment
- **topologySpreadConstraints** — optional field per deployment
- **Global values** — `global.imageRegistry` (shared registry prefix) and `global.imagePullSecrets` (fallback pull secrets)
- **Native volume spec** — volumes now accept native Kubernetes spec directly (hostPath, CSI, downwardAPI, projected, etc.) alongside the legacy `.type` format
- **Configurable default resources** — `defaults.resources` section in values.yaml for CronJob/Hook without explicit resources
- **Secret checksum** — `checksum/secret` annotation in pod template for automatic restart when secrets change
- **Version label** — `app.kubernetes.io/version` added to all labels (deployment, hook, common)
- **hostAliases and dnsConfig for root CronJob** — added for parity with root Hook and deployment-level CronJob
- **dnsConfig for root Hook** — added for parity with deployment-level Hook
- **NOTES.txt** — sections for Hooks, PDB, and NetworkPolicy in post-install output
- **values.yaml documentation** — complete documentation for strategy, revisionHistoryLimit, progressDeadlineSeconds, topologySpreadConstraints, pdb, networkPolicy, native volumes
- **Chart.yaml** — added keywords (pdb, network-policy, hpa, autoscaling) and maintainer URL

### Changed

- **imageString helper** — now accepts a dict with `global` context to support `global.imageRegistry`. Backward compatible with direct invocation
- **imagePullSecrets** — extended fallback chain: deployment/job-level → global.imagePullSecrets (in deployment, cronjob, hook)
- **Default resources CronJob/Hook** — moved from hardcoded in template to `defaults.resources` in values.yaml (same value: 100m CPU, 128Mi memory)
- **renderVolume helper** — new centralized helper for volume rendering, used by deployment, cronjob, and hook
- **HPA validation** — `minReplicas` and `maxReplicas` now use `required()` for a clear error when omitted with HPA enabled

### Fixed

- **CronJob deployment-level inheritance** — `nodeSelector`, `affinity`, `tolerations`, `imagePullSecrets` with explicit empty value now correctly override parent deployment (switched from `if not` to `hasKey`/`ternary`)
- **Hook deployment-level inheritance** — same fix for the same 4 fields
- **Resources null** — the `resources` field is no longer rendered as `resources: null` when not specified in deployment

### Removed

- **Dead ingress code** — removed all `semverCompare` code for Kubernetes <1.19 in `ingress.yaml` (chart already requires `kubeVersion: >=1.19.0-0`)

---

## [1.2.1] — 2026-03-05

### Added

- `enabled` flag support on all templates (deployment, service, serviceaccount, hpa, configmap, secret, mounted-configmap, cronjob, hook, NOTES.txt)

---

## [1.2.0] — 2026-03-04

### Added

- Complete test suite (14 suites, 174 tests)
- Template improvements and Makefile enhancements

---

## [1.1.0] — 2026-02-28

### Changed

- ServiceAccount handling update and version bump

---

## [1.0.0] — 2026-02-15

### Added

- Initial release with multi-deployment support
- Deployment, Service, Ingress, CronJob, Hook, ExternalSecret, RBAC
- Inheritance pattern for deployment-level Hook/CronJob
