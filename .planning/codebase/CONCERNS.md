# Codebase Concerns

**Analysis Date:** 2026-03-17

---

## Tech Debt

**Verification report describes a `global-chart.inheritedJobPodSpec` shared helper that does not exist:**
- Issue: The Phase 01 verification report (`/Users/filippomerante/project/github/global-chart/.planning/phases/01-template-logic-audit-bug-fixes/01-VERIFICATION.md`) claims a shared `inheritedJobPodSpec` helper was extracted to `_helpers.tpl` (Truth #9, Truth #10). The helper does NOT exist in the current `_helpers.tpl` (only 323 lines, 19 `define` blocks). Both `hook.yaml` and `cronjob.yaml` PART 2 still contain 30+ lines of inline inheritance logic each (`imagePullSecrets`, `hostAliases`, `nodeSelector`, `tolerations`, `affinity`, `podSecurityContext`, `securityContext`, `dnsConfig`).
- Files: `charts/global-chart/templates/_helpers.tpl`, `charts/global-chart/templates/hook.yaml` (lines 350–470), `charts/global-chart/templates/cronjob.yaml` (lines 264–400)
- Impact: Inheritance logic is duplicated across `hook.yaml` and `cronjob.yaml`. Any change to inherited field behavior must be applied in two places, increasing the risk of divergence.
- Fix approach: Extract the shared pod spec inheritance block into a `global-chart.inheritedJobPodSpec` helper in `_helpers.tpl` and call it from PART 2 of both templates.

**`successfulJobsHistoryLimit` and `failedJobsHistoryLimit` still use `default` (falsy masking not fully fixed):**
- Issue: Phase 01 fixed `automountServiceAccountToken` using `hasKey`, but `successfulJobsHistoryLimit` and `failedJobsHistoryLimit` still use `default 2 $job.successfulJobsHistoryLimit` (lines 63–64 and 258–259 in `cronjob.yaml`). Setting either to `0` will be silently overridden to `2`.
- Files: `charts/global-chart/templates/cronjob.yaml` lines 63, 64, 258, 259
- Impact: Users cannot set `successfulJobsHistoryLimit: 0` (common for cleanup). The value `0` is falsy in Go templates and gets replaced by `2`.
- Fix approach: Replace `default 2 $job.successfulJobsHistoryLimit` with `ternary $job.successfulJobsHistoryLimit 2 (hasKey $job "successfulJobsHistoryLimit")` at all four locations.

**Root-level CronJob `automountServiceAccountToken` still uses `default` (falsy masking):**
- Issue: Line 47 of `cronjob.yaml` uses `automountServiceAccountToken: {{ default true $job.automountServiceAccountToken }}`. Setting `automountServiceAccountToken: false` on a root-level CronJob ServiceAccount will be silently replaced with `true`. Deployment-level CronJobs (line 236) use the correct `hasKey` pattern.
- Files: `charts/global-chart/templates/cronjob.yaml` line 47
- Impact: Root-level CronJob ServiceAccounts cannot disable automounting. Security concern for workloads that should not receive cluster credentials.
- Fix approach: Replace with `hasKey` pattern matching line 210–211 behavior in the deployment-level section.

**Ingress does not validate `service.enabled: false` on referenced deployments:**
- Issue: `ingress.yaml` (line 48) validates that a referenced deployment has `enabled: false` and emits a clear error. However, it does NOT validate when a deployment has `service.enabled: false`. This means an Ingress rule can silently reference a deployment that has no Service, generating a valid-looking but broken Ingress manifest.
- Files: `charts/global-chart/templates/ingress.yaml` lines 42–57, `charts/global-chart/templates/service.yaml` lines 6–9
- Impact: Silent misconfiguration. Traffic will fail at runtime with 502/503 errors and no template-time warning.
- Fix approach: After resolving `$deploy` in the `else if $hostEntry.deployment` branch, check `$deploy.service.enabled` (using `hasKey` + `ternary`) and emit a `fail` matching the pattern of the existing disabled-deployment error.

---

## Test Coverage Gaps

**23 of 30 `fail`/`required` paths have no negative tests (Phase 02 work-in-progress):**
- What's not tested: CronJob `fromDeployment` non-existent deployment validation; missing image; HPA `minReplicas`/`maxReplicas` required; Ingress missing-deployment and missing-deployment-or-service errors; ExternalSecret `remote`, `secretstore`, `secretkey` mandatory fields; mounted ConfigMap missing `content`; `renderVolume` unknown legacy type; `renderImagePullSecrets` invalid entry.
- Files: `charts/global-chart/tests/cronjob_test.yaml`, `charts/global-chart/tests/hook_test.yaml`, `charts/global-chart/tests/deployment_test.yaml`, `charts/global-chart/tests/hpa_test.yaml`, `charts/global-chart/tests/ingress_test.yaml`, `charts/global-chart/tests/externalsecret_test.yaml`, `charts/global-chart/tests/mounted-configmap_test.yaml`, `charts/global-chart/tests/helpers_test.yaml`
- Risk: Template correctness regressions go undetected. A refactor that changes an error message will not be caught.
- Priority: High — Phase 02 is already planned and in `RESEARCH.md` with a complete inventory.

**No seven-category inheritance tests for CronJob and Hook override behavior:**
- What's not tested: Explicit `nodeSelector: {}` blocking inheritance on CronJobs; tolerations/affinity override; imagePullSecrets override; podSecurityContext override and explicit-empty; dnsConfig override per-job.
- Files: `charts/global-chart/tests/cronjob_test.yaml`, `charts/global-chart/tests/hook_test.yaml`
- Risk: Inheritance override behavior (introduced in v1.3.0) is untested for most fields. A bug in `ternary ... (hasKey ...)` logic would go undetected.
- Priority: High — Phase 02 scope includes this.

**HPA test file has only 5 tests with no negative paths:**
- What's not tested: `minReplicas` missing, `maxReplicas` missing, HPA enabled with neither CPU nor memory metric.
- Files: `charts/global-chart/tests/hpa_test.yaml`
- Risk: Misconfigured HPA (e.g., missing `maxReplicas`) renders template-time errors that won't surface until users deploy.
- Priority: Medium.

---

## Fragile Areas

**`hook.yaml` PART 2 is 302 lines with deeply nested inheritance resolution:**
- Files: `charts/global-chart/templates/hook.yaml` lines 175–476
- Why fragile: ServiceAccount resolution logic spans 90 lines (lines 195–270) with three resolution paths (explicit name, inherited from deployment, create new). Any SA inheritance fix must also be applied to the parallel block in `cronjob.yaml`. The duplicate code in both files has diverged slightly (e.g., `hook.yaml` has SA annotation support at line 246; `cronjob.yaml` has equivalent at line 216).
- Safe modification: Always verify both `hook.yaml` and `cronjob.yaml` PART 2 sections when making changes. Run `make unit-test` after each edit.
- Test coverage: Partial — SA inheritance covered for deployment-level hooks; most other fields lack seven-category tests.

**`service.yaml` uses a non-standard pattern for the `enabled` flag:**
- Files: `charts/global-chart/templates/service.yaml` lines 6–9
- Why fragile: The `deploymentEnabled` helper (`_helpers.tpl` line 88) is the standard way to handle `enabled` defaults. `service.yaml` uses a bespoke inline check: `if and (hasKey $svc "enabled") (not $svc.enabled)`. The two approaches are semantically equivalent but inconsistent. Adding a `serviceEnabled` helper analogous to `deploymentEnabled` would make the code consistent, and future readers may be confused by the inconsistency when adding new conditionals.
- Safe modification: Do not change the behavior without adding a test that verifies `service.enabled: false` skips Service creation.

**`externalsecret.yaml` uses `external-secrets.io/v1` API version (not `v1beta1`):**
- Files: `charts/global-chart/templates/externalsecret.yaml` line 9
- Why fragile: The External Secrets Operator has had multiple API version changes (v1alpha1 → v1beta1 → v1). Using `v1` requires ESO >= 0.9.0. Clusters running ESO 0.5–0.8 are still common. There is no `apiVersion` configuration option in values.yaml to allow users to override.
- Safe modification: Add an `externalSecrets.apiVersion` value (defaulting to `external-secrets.io/v1`) and use it in the template.

**`hookfullname` helper does not use `deploymentName` for deployment-level hooks:**
- Files: `charts/global-chart/templates/_helpers.tpl` line 127–130, `charts/global-chart/templates/hook.yaml` line 184
- Why fragile: The `global-chart.hookfullname` helper (used only for root-level hooks) builds `{fullname}-{hookname}-{jobname}`. Deployment-level hooks compute the fullname inline with `printf "%s-%s-%s-%s"` (hook.yaml line 184). The helper is not reused for deployment-level hooks, so there are two different name-construction patterns for essentially the same resource type.
- Safe modification: If adding a new naming feature (e.g., a global name prefix), the inline printf on line 184 must also be updated.

---

## Security Considerations

**Secrets in `values.yaml` are stored as plaintext base64 (not encrypted):**
- Risk: The `deployments.*.secret` map accepts plaintext values and encodes them with `b64enc` in `secret.yaml`. Base64 is not encryption. If values files are committed to git, secrets are exposed.
- Files: `charts/global-chart/templates/secret.yaml`, `charts/global-chart/values.yaml`
- Current mitigation: `secret.yaml` uses `type: Opaque`. No tooling enforces keeping values out of git. The recommended alternative (`externalSecrets`) exists but is opt-in.
- Recommendations: Add a prominent note in values.yaml comments that the `secret` key is for non-sensitive configuration or development only. Encourage ExternalSecrets for production use.

**`automountServiceAccountToken: true` is the default for all generated ServiceAccounts:**
- Risk: Every deployment, root-level hook, and deployment-level hook creates a ServiceAccount with `automountServiceAccountToken: true` unless explicitly disabled. Pods with unnecessary token mounting increase the attack surface if a container is compromised.
- Files: `charts/global-chart/templates/serviceaccount.yaml` line 25, `charts/global-chart/templates/hook.yaml` lines 70, 270, `charts/global-chart/templates/rbac.yaml` line 30
- Current mitigation: Users can set `serviceAccount.automount: false` per-deployment.
- Recommendations: Consider defaulting to `false` in a future major version, or add a `global.automountServiceAccountToken` default.

---

## Performance Bottlenecks

**`hook.yaml` template is 476 lines — longest template file:**
- Files: `charts/global-chart/templates/hook.yaml`
- Problem: Large template files increase Helm rendering time and make debugging harder. The file handles two separate rendering paths (root-level and deployment-level) each spanning 200+ lines.
- Cause: Duplication of ServiceAccount resolution, imagePullSecrets, inheritance logic, and ConfigMap/Secret copying.
- Improvement path: Once the shared `inheritedJobPodSpec` helper is extracted, PART 2 of hook.yaml should shrink significantly.

---

## Missing Critical Features

**No `schedule` validation for CronJobs:**
- Problem: `cronjob.yaml` passes `$job.schedule` directly to the manifest without validation. An empty or missing `schedule` field will produce a CronJob with `schedule: ""` (or render an empty value), which Kubernetes rejects at apply time rather than at `helm lint`.
- Blocks: Early error detection. Users only discover misconfiguration at cluster apply time.

**No multi-container support in Deployments:**
- Problem: Each deployment supports only one primary container (`containers[0]`) via `extraContainers` for sidecars. There is no first-class support for defining multiple main containers with individual port, resource, and probe configurations.
- Blocks: Sidecar-first architectures (e.g., Envoy proxy, log shippers) require workarounds via `extraContainers`.

**Single Ingress resource per release:**
- Problem: Only one Ingress resource is generated per Helm release (named `{release}-{chart}`). Users with complex routing needs (e.g., separate Ingress classes, different annotations per host group) cannot create multiple Ingress resources.
- Blocks: Multi-ingress-class deployments.

---

## Dependencies at Risk

**`helm-unittest` pinned to Docker image `helmunittest/helm-unittest:3.19.0-1.0.3` (test-only):**
- Risk: Docker-based test runner. If the Docker Hub image is unavailable or deprecated, CI is blocked. No local fallback is documented.
- Impact: `make unit-test` fails; CI pipeline blocks.
- Migration plan: Document helm-unittest local plugin as fallback. Pin by digest rather than tag.

---

*Concerns audit: 2026-03-17*
