# Codebase Concerns

**Analysis Date:** 2026-03-15

---

## Tech Debt

**Legacy Volume Format Still Supported:**
- Issue: Two volume specification formats coexist — the legacy `.type`-keyed format and native Kubernetes spec. The legacy path is preserved for backward compatibility, adding a branching code path in the `renderVolume` helper.
- Files: `charts/global-chart/templates/_helpers.tpl` (lines 199–223), `charts/global-chart/values.yaml` (comments)
- Impact: New users may accidentally use the legacy format; the helper must grow every time a new legacy type is requested (currently only supports `emptyDir`, `configMap`, `secret`, `persistentVolumeClaim`).
- Fix approach: Deprecate the legacy `.type` format in a minor release by adding a warning comment, then remove in v2.0.0. Native format already handles all Kubernetes volume types.

**Duplicate Inheritance Logic in `hook.yaml` and `cronjob.yaml`:**
- Issue: The logic for resolving ServiceAccount, imagePullSecrets, hostAliases, podSecurityContext, securityContext, nodeSelector, tolerations, affinity, envFrom, and env inheritance from a parent deployment is duplicated nearly verbatim between `charts/global-chart/templates/hook.yaml` (lines 196–418) and `charts/global-chart/templates/cronjob.yaml` (lines 177–405). Any fix or new feature must be applied in two places.
- Files: `charts/global-chart/templates/hook.yaml`, `charts/global-chart/templates/cronjob.yaml`
- Impact: High risk of divergence — a fix applied to hooks may be missed for cronjobs or vice versa. Makes templates harder to audit.
- Fix approach: Extract the shared pod-spec rendering logic into a `_helpers.tpl` named template (e.g., `global-chart.inheritedJobPodSpec`) that both templates call. This is a medium-refactoring effort requiring careful testing.

**Duplicate `saCreate`/`saName` Resolution Logic:**
- Issue: ServiceAccount resolution logic (explicit name, inherit from deployment, create new) is duplicated with slight variation between `hook.yaml` (lines 196–234) and `cronjob.yaml` (lines 177–207). The hook version also handles the `serviceAccount.create` map key check; the cronjob version omits the `deploySA.name` (existing SA) inheritance path that hooks support.
- Files: `charts/global-chart/templates/hook.yaml`, `charts/global-chart/templates/cronjob.yaml`
- Impact: CronJobs inside deployments do NOT inherit from an existing SA (`serviceAccount.create: false` + `name: xxx`) — hooks do, cronjobs don't. This is a functional asymmetry that may surprise users.
- Fix approach: Unify into a shared helper; ensure CronJob SA inheritance matches Hook SA inheritance behavior.

**Root-level CronJob SA Logic Simplified vs Deployment-level:**
- Issue: Root-level CronJob (`cronjob.yaml` lines 32–48) uses a simpler SA check (`and (hasKey ...) (hasKey ...) $job.serviceAccount.create`) compared to the deployment-level variant which uses `ternary` + `hasKey` patterns. The root-level variant does not support the `serviceAccount.name` without `create: true` pattern.
- Files: `charts/global-chart/templates/cronjob.yaml` (lines 32–48)
- Impact: Slight inconsistency in SA configuration UX between root-level and deployment-level CronJobs.
- Fix approach: Align root-level CronJob SA handling to match the deployment-level pattern.

**`externalSecrets` Only Supports a Single `data` Entry:**
- Issue: `charts/global-chart/templates/externalsecret.yaml` renders exactly one `data[0]` entry per ExternalSecret resource (one `remoteRef`/`secretKey` pair). Users needing multiple keys from the same secret store must declare multiple ExternalSecret objects.
- Files: `charts/global-chart/templates/externalsecret.yaml`
- Impact: Verbose values for common use cases (e.g., pulling multiple keys from one vault path).
- Fix approach: Change `data` from a single-entry block to a list, accepting `data: [{secretkey, remote: {...}}]` and ranging over it.

**`rbac.yaml` Generates Positional Role Names:**
- Issue: When no `name` is provided in an RBAC role entry, the role is named `{fullname}-role-{index}` using the array index. Array position is not stable across upgrades if roles are reordered.
- Files: `charts/global-chart/templates/rbac.yaml` (line 5)
- Impact: Reordering the `rbacs.roles` list in values causes old Role/RoleBinding resources to be replaced with new names, potentially leaving orphaned resources.
- Fix approach: Require `name` to be explicit for all RBAC roles, or use a more stable default like a hash of the rules.

---

## Security Considerations

**Secrets Stored in Plain Text in Helm Values:**
- Risk: The `deployments.<name>.secret` map in values accepts plain-text key/value pairs which are then base64-encoded (not encrypted) into a Kubernetes `Secret`. Values are visible to anyone who can run `helm get values` or inspect the release secret in the cluster.
- Files: `charts/global-chart/templates/secret.yaml`, `charts/global-chart/values.yaml`
- Current mitigation: Documentation recommends ExternalSecrets CRD for production secret management.
- Recommendations: Add a warning in `NOTES.txt` that `deployments.*.secret` values are not encrypted. Encourage use of `externalSecrets` or `envFromSecrets` referencing pre-existing secrets for production workloads.

**`automountServiceAccountToken` Defaults to `true`:**
- Risk: All generated ServiceAccounts default to `automountServiceAccountToken: true` (deployments, hooks, cronjobs, RBAC SAs). This mounts the SA token into every pod, which is unnecessary for most workloads and expands the attack surface.
- Files: `charts/global-chart/templates/serviceaccount.yaml` (line 23), `charts/global-chart/templates/hook.yaml` (line 70), `charts/global-chart/templates/cronjob.yaml` (line 236), `charts/global-chart/templates/rbac.yaml` (line 30)
- Current mitigation: Can be overridden per-deployment via `serviceAccount.automount: false`.
- Recommendations: Change the default to `false`; this is a breaking change for users who depend on the token being mounted implicitly. Alternatively, document this prominently.

**Helm Test Pod Uses Unpinned `busybox:1.36` Image:**
- Risk: The test-connection pod uses `busybox:1.36` with no digest pin. In air-gapped or policy-controlled environments the tag may be pulled from an untrusted registry, or the tag may drift.
- Files: `charts/global-chart/templates/tests/test-connection.yaml` (line 30)
- Current mitigation: None.
- Recommendations: Either pin the image by digest or make the test image configurable via values (e.g., `testConnection.image`).

**No validation of `hookType` / `concurrencyPolicy` / `restartPolicy` values:**
- Risk: Template accepts arbitrary string for `hookType` (e.g., `pre-install`, `post-upgrade`) and `restartPolicy`/`concurrencyPolicy` without validation. Invalid values produce broken Kubernetes manifests that fail at apply time rather than at `helm lint` time.
- Files: `charts/global-chart/templates/hook.yaml`, `charts/global-chart/templates/cronjob.yaml`
- Current mitigation: `helm lint --strict` will catch schema issues only if a JSON schema (`values.schema.json`) is present — none exists.
- Recommendations: Add `charts/global-chart/values.schema.json` to enforce allowed values for frequently-misused fields.

---

## Performance Bottlenecks

**`toYaml | sha256sum` on Every Pod Render:**
- Problem: `deployment.yaml` lines 38–40 compute SHA256 checksums of `configMap`, `secret`, and `mountedConfigFiles` on every pod template render using `toYaml $deploy.configMap | sha256sum`. For large ConfigMaps this is repeated in every deployment iteration.
- Files: `charts/global-chart/templates/deployment.yaml` (lines 38–40)
- Cause: Helm template rendering is CPU-bound and single-threaded; large maps amplify this.
- Improvement path: Low priority — Helm renders are fast for typical chart sizes. Would become noticeable only with very large configMap data blobs. No actionable fix beyond keeping configMap values small.

---

## Fragile Areas

**`ingress.yaml` Has No Guard Against Empty `hosts` List:**
- Files: `charts/global-chart/templates/ingress.yaml`
- Why fragile: If `ingress.enabled: true` is set but `ingress.hosts` is empty (or the default `chart-example.local` entry has neither `deployment` nor `service.name`), the template renders an Ingress with zero rules but does not fail cleanly. The default values include a `host: chart-example.local` entry with `deployment: ""` and `service.name: ""`, which will trigger the `fail` on line 56 only when ingress is enabled — this is a useful guard but the default values file itself sets up the failure condition.
- Safe modification: Always provide `deployment:` or `service.name:` on each host entry when enabling Ingress. The default values entry must be replaced, not supplemented.
- Test coverage: `charts/global-chart/tests/ingress_test.yaml` covers deployment/service reference paths but does not test empty hosts list.

**`hookfullname` Helper Does Not Use `deploymentName` Parameter:**
- Files: `charts/global-chart/templates/_helpers.tpl` (lines 127–130)
- Why fragile: `global-chart.hookfullname` requires `.hookname` and `.jobname` to be set on the dict via `merge`, but the helper is only used for root-level hooks. Deployment-level hooks compute the full name inline in `hook.yaml` line 184 using `printf` directly — bypassing the helper. These two approaches can drift.
- Safe modification: When changing the naming convention for hooks, remember to update both the `hookfullname` helper AND the inline `printf` on line 184 of `hook.yaml` and line 166 of `cronjob.yaml`.
- Test coverage: `charts/global-chart/tests/hook_test.yaml` tests names for both root and deployment-level hooks.

**Deployment-level CronJob SA Inheritance Asymmetry:**
- Files: `charts/global-chart/templates/cronjob.yaml` (lines 184–207)
- Why fragile: When `serviceAccount.create: false` with `name: xxx` is set on a deployment, deployment-level CronJobs do NOT inherit the named SA (the `deploySA.name` branch is missing, unlike in `hook.yaml` line 209). This means a CronJob inside such a deployment will fall through to creating its own SA unnecessarily.
- Safe modification: Add the `else if $deploySA.name` branch to the CronJob SA resolution block matching `hook.yaml` lines 208–212. Requires a unit test to verify.
- Test coverage: Gap — `charts/global-chart/tests/cronjob_test.yaml` likely does not test the `create: false` + `name:` cronjob case.

**No `values.schema.json` for Input Validation:**
- Files: `charts/global-chart/` (missing file)
- Why fragile: Without a JSON schema, malformed values (wrong types, missing required fields, invalid enum values) are not caught at `helm lint` or `helm install` time — they either silently produce wrong output or fail with cryptic template errors.
- Safe modification: Adding a schema is purely additive. New fields should always be added to the schema when added to `values.yaml`.
- Test coverage: Not applicable; this is a gap in the chart's defensive validation layer.

---

## Test Coverage Gaps

**CronJob SA Inheritance for `create: false` + `name:`:**
- What's not tested: Whether a deployment-level CronJob correctly inherits (or fails to inherit) the SA when the deployment uses `serviceAccount.create: false` with an explicit `name`.
- Files: `charts/global-chart/tests/cronjob_test.yaml`
- Risk: The functional asymmetry with hooks (documented above) would go undetected.
- Priority: High — this is an existing behavioral bug.

**Ingress with Empty or Invalid `hosts` List:**
- What's not tested: Rendering `ingress.enabled: true` with `hosts: []` or with the default stub `host: chart-example.local` that has neither `deployment` nor `service.name`.
- Files: `charts/global-chart/tests/ingress_test.yaml`
- Risk: Confusing render-time failure for users who enable ingress without replacing default host entry.
- Priority: Medium.

**ExternalSecret with Multiple Keys:**
- What's not tested: Attempting to define multiple keys from the same SecretStore — the template only supports one key per ExternalSecret object. The limitation is not tested or documented in test files.
- Files: `charts/global-chart/tests/externalsecret_test.yaml`
- Risk: User confusion; no clear error, just incomplete secret population.
- Priority: Low (this is a feature gap, not a correctness bug).

**`renderVolume` Unknown Legacy Type Error Path:**
- What's not tested: Providing a `.type` value that isn't `emptyDir`, `configMap`, `secret`, or `persistentVolumeClaim` to verify the `fail` message fires correctly.
- Files: `charts/global-chart/tests/deployment_test.yaml` (missing negative test for `renderVolume`)
- Risk: If the `fail` block is broken, an unknown type silently produces malformed YAML.
- Priority: Low.

---

## Dependencies at Risk

**`HELM_DOCS_IMAGE` Pinned to `:latest`:**
- Risk: `Makefile` line 11 uses `jnorwood/helm-docs:latest`, which may update unexpectedly and change doc formatting or behavior in CI.
- Files: `Makefile` (line 11)
- Impact: Non-deterministic `make generate-docs` output.
- Migration plan: Pin to a specific `helm-docs` version tag, e.g., `jnorwood/helm-docs:v1.14.2`.

**`actions/checkout@v6` in CI Workflows:**
- Risk: `actions/checkout@v6` is pinned to a major version, meaning minor/patch updates apply automatically without review.
- Files: `.github/workflows/helm-ci.yml` (line 12), `.github/workflows/release.yml` (line 12)
- Impact: A breaking patch in `checkout@v6` could silently break CI without a code change.
- Migration plan: Pin to a specific SHA or use Renovate to manage version bumps (Renovate config is present at `renovate.json`).

---

## Missing Critical Features

**No `values.schema.json`:**
- Problem: There is no JSON schema validation file for the chart's values. Users making typos in field names (e.g., `imagePullSecert` instead of `imagePullSecrets`) receive no error — the field is silently ignored.
- Blocks: Reliable user-facing validation; kube-linter and `helm lint --strict` can catch structural issues but not value-level type errors.

**Single-key `externalSecrets` per Resource:**
- Problem: Each entry in `externalSecrets` produces exactly one `spec.data[]` item. There is no way to pull multiple keys from the same SecretStore into a single Kubernetes Secret object via this chart.
- Blocks: Clean multi-key secret synchronization patterns; workaround is declaring multiple ExternalSecret values entries.

**No `ClusterRole` / `ClusterRoleBinding` Support in RBAC:**
- Problem: `charts/global-chart/templates/rbac.yaml` only generates namespace-scoped `Role` and `RoleBinding` resources. Cluster-scoped RBAC is not supported.
- Blocks: Use cases requiring cross-namespace or cluster-level permissions (e.g., operators, monitoring agents).

---

*Concerns audit: 2026-03-15*
