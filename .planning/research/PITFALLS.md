# Pitfalls Research

**Domain:** Helm chart quality audit & hardening (Go templates, helm-unittest, Kubernetes manifests)
**Researched:** 2026-03-15
**Confidence:** HIGH (grounded in codebase analysis + verified community patterns)

## Critical Pitfalls

### Pitfall 1: `default` Silently Swallows `false`, `0`, and `""`

**What goes wrong:**
Go templates treat `false`, `0`, `""`, `nil`, and empty collections as "falsy." The `default` function replaces falsy values with the default, so `default true $val` where `$val` is `false` returns `true` -- the opposite of what the user set. This is the single most common source of silent misconfiguration in Helm charts.

**Why it happens:**
Developers familiar with languages where `default` means "if undefined" don't realize Go's `default` means "if falsy." The pattern `default true .Values.foo` looks correct but silently ignores explicit `false`.

**How to avoid:**
Use `hasKey` + `ternary` for every boolean, zero-valid integer, and empty-string-valid field:
```yaml
{{- $create := ternary $sa.create true (hasKey $sa "create") -}}
```
This chart already follows this pattern in many places (CONVENTIONS.md documents it), but an audit must verify every single `default` call in templates is not masking a valid falsy value.

**Warning signs:**
- Any `default true`, `default false`, `default 0` call in templates
- `replicaCount | default 2` -- safe only if `replicaCount: 0` is never valid (it isn't for deployments, but verify)
- User reports "I set X but it's being ignored"

**Phase to address:**
Phase 1 (Template Logic Audit) -- grep all `default` calls and validate each one.

---

### Pitfall 2: Nil Pointer Panics on Optional Nested Maps

**What goes wrong:**
Accessing `.Values.deployments.frontend.serviceAccount.create` panics if `serviceAccount` is not defined. Go templates do not have optional chaining -- accessing a key on a nil map is a fatal error, not a nil return.

**Why it happens:**
YAML users expect that omitting a section means "use defaults." In most languages, `obj?.nested?.field` returns nil. Go templates crash instead.

**How to avoid:**
Every optional sub-map must be guarded with `default (dict)`:
```yaml
{{- $sa := default (dict) $deploy.serviceAccount -}}
```
This chart uses this pattern extensively, but the audit must verify every nested access path -- one missed `default (dict)` in a rarely-used code path will crash only when that specific combination of values is used.

**Warning signs:**
- Template rendering fails with `nil pointer evaluating interface {}` only for specific value combinations
- New template code accesses nested fields without `default (dict)` guard
- Test coverage doesn't exercise the "field omitted" path

**Phase to address:**
Phase 1 (Template Logic Audit) -- systematic review of every nested map access.

---

### Pitfall 3: Duplicated Logic Drifts Between hook.yaml and cronjob.yaml

**What goes wrong:**
The inheritance logic for deployment-level hooks and cronjobs (SA resolution, imagePullSecrets, nodeSelector, tolerations, etc.) is duplicated nearly verbatim across two files (~200 lines each). A fix applied to one file gets missed in the other. The codebase already has a concrete example: CronJob SA inheritance is missing the `deploySA.name` branch that hooks have, causing an asymmetry where hooks inherit existing SAs but cronjobs don't.

**Why it happens:**
Go templates lack proper functions with return values -- `define`/`include` returns a string, making it awkward to share structured logic. Copy-paste is the path of least resistance.

**How to avoid:**
Extract shared pod-spec rendering into a named template in `_helpers.tpl`. While Go template helpers return strings (not structured data), the inheritance resolution logic (which fields to pick from job vs deployment) can be factored into helpers that return resolved values. The actual YAML rendering stays in the template but uses resolved variables.

**Warning signs:**
- Any PR that modifies `hook.yaml` lines 196-418 without a corresponding change in `cronjob.yaml` lines 177-405
- Test passes for hooks but fails (or is missing) for cronjobs on the same feature
- User reports "feature X works for hooks but not cronjobs"

**Phase to address:**
Phase 1 (Template Logic Audit) to fix the existing SA asymmetry; Phase 3 (Refactoring) to extract shared helpers.

---

### Pitfall 4: No values.schema.json Means Silent Typos

**What goes wrong:**
Without a JSON schema, Helm silently ignores misspelled keys. A user writes `imagePullSecert` instead of `imagePullSecrets` and gets no error -- the deployment just runs without pull secrets and fails with `ImagePullBackOff` in the cluster. This is the most common source of "it works in staging, fails in production" issues with Helm charts.

**Why it happens:**
Helm treats values.yaml as a free-form map. Any key is valid. There is no "unknown key" warning without a schema. Users assume Helm validates their input.

**How to avoid:**
Create `values.schema.json` with:
- Required fields marked (e.g., `image` in each deployment)
- Enum constraints for fields with limited valid values (`restartPolicy`, `concurrencyPolicy`, `hookType`, `strategy.type`)
- Type constraints (boolean for `enabled`, integer for `replicaCount`)
- `additionalProperties: false` at critical levels to catch typos

Use `helm-values-schema-json` plugin or `dadav/helm-schema` to generate a starting schema from values.yaml, then refine manually. Note: Helm only validates keys present in the schema -- it does NOT flag keys in values that are absent from the schema unless `additionalProperties: false` is set.

**Warning signs:**
- Users report "I set this value but nothing changed"
- `helm lint` passes but manifests are wrong
- No schema file exists in the chart directory

**Phase to address:**
Phase 2 (Validation & Schema) -- dedicated phase because schema creation is substantial work for a chart this complex.

---

### Pitfall 5: Breaking Backward Compatibility During Hardening

**What goes wrong:**
Security hardening changes defaults in ways that break existing consumers. Classic examples:
- Changing `automountServiceAccountToken` default from `true` to `false` breaks workloads that need the SA token (e.g., for AWS IRSA, GCP Workload Identity, or any pod that calls the Kubernetes API)
- Adding `securityContext.runAsNonRoot: true` as default breaks images that run as root
- Adding `readOnlyRootFilesystem: true` breaks containers that write to `/tmp` or `/var`
- Making `resources` required breaks users who intentionally omit them for dev clusters

**Why it happens:**
Audit recommendations say "set X to secure value" without considering that existing consumers rely on the current defaults. A hardening audit that changes defaults is a breaking change disguised as a best practice.

**How to avoid:**
- Never change defaults in a minor/patch release -- only in a major version bump
- For security improvements, add the fields as opt-in first (document them, add to schema) and change defaults in the next major version
- Use `NOTES.txt` to warn about insecure defaults rather than silently changing them
- Provide a "hardened" values overlay file (e.g., `values-hardened.yaml`) that users can merge

**Warning signs:**
- PR changes a default value in `values.yaml` or in a `default`/`ternary` call in templates
- `make lint-chart` passes but existing consumer values files would produce different output
- No changelog entry mentioning the default change

**Phase to address:**
Every phase -- this is a cross-cutting concern. Each fix PR must be evaluated for backward compatibility.

---

### Pitfall 6: Helm Test Coverage False Confidence

**What goes wrong:**
helm-unittest tests assert YAML structure but cannot validate:
- Whether the rendered manifest is valid Kubernetes (e.g., `restartPolicy: Sometimes` passes helm-unittest but fails `kubectl apply`)
- Whether resources interact correctly (e.g., Service selector matches Deployment labels)
- Whether the chart upgrades cleanly from version N to N+1
- Whether `fail` messages actually fire (helm-unittest can test `failedTemplate` but many charts don't)

Teams see "220 tests passing" and assume the chart is bulletproof, missing entire categories of bugs.

**Why it happens:**
helm-unittest is a template-output assertion tool. It renders templates and checks YAML paths. It has no Kubernetes API knowledge, no schema validation, and no multi-resource relationship checking.

**How to avoid:**
Layer testing tools:
1. **helm-unittest** -- template logic correctness (current: 220 tests)
2. **helm lint --strict** -- basic structural validation (current: in CI)
3. **kubeconform** or **kubeval** -- validate rendered manifests against Kubernetes OpenAPI schemas
4. **kube-linter** -- security and best practice checks (current: available via `make kube-linter` but not in CI)
5. **Conftest/OPA** -- policy-as-code for organization-specific rules
6. **chart-testing (ct)** -- install/upgrade testing on a real cluster (not in current CI)

The biggest gap in this chart is that kube-linter is available but not in CI, and kubeconform is entirely absent.

**Warning signs:**
- Tests only assert `matchSnapshot` or `equal` on happy paths
- No negative tests (testing that invalid input produces `failedTemplate`)
- No rendered-manifest validation in CI
- No upgrade path testing

**Phase to address:**
Phase 2 (Test Coverage) for adding negative tests; Phase 3 for CI pipeline hardening with kubeconform and kube-linter.

---

### Pitfall 7: Name Truncation Silently Creates Collisions

**What goes wrong:**
Resource names are truncated to 63 characters (52 for CronJobs). When multiple deployments have long names with the same prefix, truncation produces identical names. Example: `myrelease-global-chart-very-long-deployment-name-api` and `myrelease-global-chart-very-long-deployment-name-worker` both truncate to 52 chars as `myrelease-global-chart-very-long-deployment-name-ap` and `myrelease-global-chart-very-long-deployment-name-wo` -- these are different, but with longer prefixes they collide.

Worse, `trimSuffix "-"` after truncation means names ending in `-` get further shortened, potentially creating unexpected collisions.

**Why it happens:**
Kubernetes DNS naming spec limits names. Helm's standard `trunc 63 | trimSuffix "-"` is the conventional approach but provides no collision detection. CronJob's 52-char limit (because K8s appends 11-char timestamps) makes this more likely.

**How to avoid:**
- Document maximum safe lengths for deployment names given the release name and chart name
- Add a `fail` guard in `deploymentFullname` when truncation actually occurs, warning the user
- Test with long names in helm-unittest to verify truncation behavior
- Consider using a hash suffix for disambiguation (but this hurts readability)

**Warning signs:**
- Release name + chart name already consume 30+ characters of the 63-char budget
- Multiple deployments with names sharing a long common prefix
- CronJobs inside deployments (name = `release-chart-deployment-cronjob`, easily exceeds 52)

**Phase to address:**
Phase 1 (Template Logic Audit) -- add validation; Phase 2 (Test Coverage) -- add long-name test cases.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Copy-paste hook/cronjob inheritance logic | Ships faster, avoids complex helper design | Every change requires two edits; asymmetries accumulate (SA bug already exists) | Never -- extract to helpers as soon as a second consumer exists |
| Legacy volume `.type` format | Backward compatible for existing users | Two code paths to maintain; new users confused by docs showing both formats | Acceptable until v2.0.0 major release; deprecation warning needed now |
| Positional RBAC role names (`role-{index}`) | Works for static configs | Reordering roles orphans old resources on upgrade | Never in production -- require explicit `name` field |
| Single-key ExternalSecret | Simpler template | Users create N ExternalSecret objects for N keys from same store | Acceptable for MVP; fix in feature gap phase |
| `busybox:1.36` unpinned in test pod | Convenient for testing | Drifts silently; fails in air-gapped environments | Never in a chart meant for enterprise use |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| ExternalSecrets Operator | Assuming `ExternalSecret` CRD exists in cluster | Add a check or document prerequisite; template renders but `kubectl apply` fails if CRD is missing |
| Ingress Controller | Setting `ingressClassName` to a class that doesn't exist; no validation possible at render time | Document required ingress controller; consider adding a `NOTES.txt` reminder |
| HPA + PDB interaction | Setting `pdb.minAvailable` equal to `hpa.minReplicas` -- HPA can't scale down because PDB blocks eviction | Document that `minAvailable` should be less than `minReplicas`; add a `fail` guard if both are set and equal |
| IRSA/Workload Identity | Setting `automountServiceAccountToken: false` on an SA used for cloud IAM breaks authentication | Document that SA token mount is required for IRSA/GCP WI; provide example values |
| ArgoCD/Flux sync | Chart version not bumped after changes; GitOps tools don't detect updates | Always bump `Chart.yaml` version; add CI check that version changed if templates changed |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| sha256sum on large ConfigMap data | Slow `helm template` rendering | Keep ConfigMap values small; use mounted files for large configs | >100KB ConfigMap values per deployment |
| Many deployments in single release | Helm release secret exceeds etcd 1MB limit | Limit to ~20 deployments per release; split into sub-charts | >50 deployments or very large per-deployment configs |
| range over large values maps | Template rendering timeout in CI | No practical limit for typical charts; only theoretical | >100 deployments with complex inheritance |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| `automountServiceAccountToken: true` default | Every pod gets a SA token; compromised pod can call Kubernetes API | Default to `false`; require explicit opt-in (breaking change -- defer to v2.0.0) |
| No `securityContext` defaults in chart | Users deploy containers as root with full capabilities | Add recommended defaults in `values.yaml` (commented out) and document; don't enforce as default (backward compat) |
| Plain-text secrets in values.yaml | Secrets in git history, visible in `helm get values` | Warn in NOTES.txt; recommend ExternalSecrets; add schema description warning |
| No `networkPolicy` by default | All pod-to-pod traffic allowed | Document; provide example values; don't enable by default (breaks legitimate traffic) |
| Unpinned test image (`busybox:1.36`) | Supply chain risk; image tag could be replaced | Pin by digest or make configurable via values |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Default `ingress.hosts` entry with empty `deployment` field | Enabling ingress without replacing defaults causes cryptic `fail` message | Remove default host entry; add clear comment "replace this entire block" |
| `service.enabled` defaults to true implicitly | Workers/background jobs get unwanted Services; user must know to set `enabled: false` | Document this prominently; consider requiring explicit `service.enabled: true` for v2.0.0 |
| CronJob SA inheritance differs from Hook SA inheritance | User expects consistent behavior; cronjobs silently create new SA instead of inheriting | Fix the asymmetry (Phase 1); document inheritance rules in values.yaml comments |
| No autocomplete/IDE support without schema | Users guess field names from examples | Create `values.schema.json` -- provides autocomplete in VS Code with YAML extension |
| `hookType` accepts any string | User writes `pre-Install` (capital I); hook silently becomes a regular job | Validate `hookType` against allowed values via schema or `fail` in template |

## "Looks Done But Isn't" Checklist

- [ ] **Schema validation:** Chart has 220 tests but no `values.schema.json` -- invalid input types pass silently
- [ ] **Negative tests:** Tests verify happy paths but don't verify that invalid configs produce clear `fail` messages
- [ ] **Upgrade testing:** No test verifies that upgrading from v1.2.0 to v1.3.0 with existing values works without manual intervention
- [ ] **kube-linter in CI:** `make kube-linter` exists but is not in the GitHub Actions workflow -- security checks run only when developers remember
- [ ] **kubeconform validation:** Rendered manifests are generated in CI but never validated against Kubernetes schemas
- [ ] **CronJob SA inheritance parity:** Hooks and CronJobs claim to inherit from deployments but CronJobs miss the `create: false` + `name` path
- [ ] **ExternalSecret multi-key:** Template "supports" ExternalSecrets but only one key per resource -- users discover this limitation at deploy time
- [ ] **RBAC ClusterRole:** RBAC template exists but only supports namespace-scoped roles -- cluster-scoped use cases silently get wrong resource type

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| `default` masking falsy values | LOW | Grep for `default` calls; replace with `hasKey`+`ternary`; add tests for falsy values |
| Nil pointer on nested map | LOW | Add `default (dict)` guard; add test with minimal values |
| Hook/CronJob logic drift | MEDIUM | Fix immediate SA bug; plan refactoring to shared helper; add parity tests |
| Missing values.schema.json | MEDIUM | Generate starter schema; refine manually; add to CI lint |
| Backward-incompatible default change | HIGH | If already released: hotfix to restore old default; document migration path; bump major version for new default |
| Name truncation collision | HIGH | If resources already deployed with colliding names: manual cleanup required; add fail guard to prevent recurrence |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| `default` masking falsy values | Phase 1: Template Logic Audit | Zero `default` calls on boolean/zero-valid fields; test with `false`/`0` values |
| Nil pointer on nested maps | Phase 1: Template Logic Audit | Every nested map access has `default (dict)` guard; test with minimal values |
| Hook/CronJob logic drift | Phase 1: Template Logic Audit (fix) + Phase 3: Refactoring (extract) | CronJob SA inheritance matches Hook SA inheritance; shared helper exists |
| Missing values.schema.json | Phase 2: Validation & Schema | Schema file exists; `helm lint` catches typos and wrong types |
| Breaking backward compatibility | All phases (cross-cutting) | Each PR documents whether defaults change; semver respected |
| Test false confidence | Phase 2: Test Coverage | kubeconform + kube-linter in CI; negative tests for all `fail` paths |
| Name truncation collisions | Phase 1: Template Logic Audit | `fail` guard on truncation; long-name test cases exist |
| Security context defaults | Phase 3: K8s Best Practices | Documented recommended security context; hardened values overlay available |
| Unpinned test image | Phase 1: Template Logic Audit | Test image configurable via values or pinned by digest |

## Sources

- [The Real State of Helm Chart Reliability (2025)](https://www.prequel.dev/blog-post/the-real-state-of-helm-chart-reliability-2025-hidden-risks-in-100-open-source-charts) -- audit of 100+ charts finding 93% overprivileged SAs
- [Helm Chart Testing Best Practices](https://alexandre-vazquez.com/helm-chart-testing-best-practices/) -- testing layers and CI pipeline recommendations
- [helm/helm#8026](https://github.com/helm/helm/issues/8026) -- nil pointer evaluating interface with `default` function
- [Kubernetes Security Context Best Practices (Wiz)](https://www.wiz.io/academy/container-security/kubernetes-security-context-best-practices) -- runAsNonRoot, readOnlyRootFilesystem guidance
- [Pod Security Standards (Kubernetes official)](https://kubernetes.io/docs/concepts/security/pod-security-standards/) -- baseline and restricted profiles
- [Validating Helm Chart Values with JSON Schemas](https://www.arthurkoziel.com/validate-helm-chart-values-with-json-schemas/) -- schema creation patterns
- [dadav/helm-schema](https://github.com/dadav/helm-schema) -- schema generation tool
- [How to Write and Run Tests for Helm Charts](https://oneuptime.com/blog/post/2026-01-17-helm-chart-testing-unittest-conftest/view) -- helm-unittest + conftest layering
- Codebase analysis: `.planning/codebase/CONCERNS.md`, `.planning/codebase/CONVENTIONS.md`

---
*Pitfalls research for: Helm chart quality audit & hardening*
*Researched: 2026-03-15*
