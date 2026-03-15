# Feature Research

**Domain:** Enterprise-grade reusable Helm chart (multi-deployment Kubernetes resource generator)
**Researched:** 2026-03-15
**Confidence:** HIGH

## Feature Landscape

### Table Stakes (Users Expect These)

Features users assume exist. Missing these = chart feels incomplete or untrustworthy for production use.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| `values.schema.json` validation | Every serious Helm chart validates input at lint/install time. Without it, typos in field names are silently ignored. Helm 3+ natively supports JSON Schema; Helm 4 adds JSON Schema 2020. Bitnami, bjw-s, and all major charts ship schemas. | HIGH | Large surface area: must cover deployments map, all nested objects, enums for hookType/restartPolicy/concurrencyPolicy/strategy type. Can be built incrementally. **Currently missing.** |
| Secure-by-default `securityContext` | Pod Security Standards (Restricted profile) are the industry norm. Bitnami, Falco, cert-manager charts all default to `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `drop: [ALL]`, `seccompProfile: RuntimeDefault`. Cluster policies (Kyverno, OPA Gatekeeper) reject pods without these. | MEDIUM | Current chart ships empty `securityContext: {}` and `podSecurityContext: {}`. Needs sensible defaults in `values.yaml` that users can override. May be a soft breaking change if existing consumers rely on root. |
| Resource requests/limits defaults | Production clusters enforce LimitRange or ResourceQuota. Charts without default resource specs cause admission failures or noisy-neighbor problems. | LOW | Chart has `defaults.resources` for CronJobs/Hooks but no default resources for Deployments. Add recommended defaults in `values.yaml` comments or actual defaults. |
| Liveness/readiness/startup probes support | Every Deployment chart supports health probes. Without them, Kubernetes cannot manage pod lifecycle correctly. | LOW | **Already supported** in deployment spec. Verify template handles all three probe types (liveness, readiness, startup) and passes through arbitrary probe config. |
| `automountServiceAccountToken` defaults to `false` | Security best practice: do not mount SA tokens unless needed. Bitnami charts default to false. PSS Restricted profile recommends it. | LOW | **Currently defaults to true.** Changing to `false` is a breaking change for workloads that need the token (e.g., jobs with RBAC). Must be opt-in per deployment. |
| Configurable test connection image | Air-gapped and policy-controlled clusters cannot pull arbitrary images. The test-connection pod's `busybox:1.36` must be configurable. | LOW | **Currently hardcoded.** Add `testConnection.image` to values. |
| Multi-key ExternalSecret support | ExternalSecrets CRD supports multiple `data[]` entries per Secret. Requiring one ExternalSecret per key is unnecessarily verbose and non-standard. | LOW | **Currently single-key only.** Change `data` to a list. |
| CHANGELOG per release | Users need to know what changed. Bitnami auto-generates CHANGELOGs per chart version. ArtifactHub expects it. | LOW | **Currently missing.** Can be generated from git log or maintained manually. |
| Consistent SA inheritance (CronJob parity with Hook) | When hooks inherit SA from parent deployment, CronJobs must too. Asymmetric behavior is a bug, not a feature choice. | LOW | **Known bug** per CONCERNS.md. CronJobs miss the `deploySA.name` branch. |

### Differentiators (Competitive Advantage)

Features that set global-chart apart from generic charts like Stakater Application or bjw-s common-library.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Multi-deployment fan-out from single release | Unique selling point: deploy frontend + backend + worker in one `helm install`. Stakater and bjw-s do single-workload per release. This is already global-chart's core differentiator. | N/A | **Already implemented.** Protect and enhance this. |
| Deployment-scoped Jobs/CronJobs with full inheritance | Jobs that auto-inherit image, env, secrets, SA from parent deployment. Reduces config duplication massively. Neither Stakater nor bjw-s offer this. | N/A | **Already implemented.** Fix the SA asymmetry bug and this is best-in-class. |
| Compile-time validation with `fail` | Catching invalid config at render time (not apply time) is rare. Most charts silently produce broken manifests. global-chart already does this for PDB, NetworkPolicy, Ingress, volumes. | LOW | **Already implemented.** Extend to more fields: require `image` on every deployment, validate `hookType` enum, validate `restartPolicy` enum. |
| `values.schema.json` with IDE autocomplete | Beyond validation: a JSON schema enables VS Code / IntelliJ autocomplete for values files. bjw-s has this; most generic charts do not. Combined with multi-deployment complexity, this is high value. | HIGH | Not just validation but DX. Users editing complex multi-deployment values get inline docs and error highlighting. |
| Kubeconform validation in CI | Validate rendered manifests against specific Kubernetes API versions. Catches deprecated API usage before cluster apply. chart-testing (ct) is the gold standard. | MEDIUM | **Currently missing from CI.** Add `kubeconform` step after `make generate-templates`. Supports CRD schemas for ExternalSecrets. |
| Multi-Kubernetes-version CI matrix | Test chart against K8s 1.27, 1.28, 1.29, 1.30 API schemas. Ensures forward/backward compatibility. | MEDIUM | Kubeconform supports `-kubernetes-version` flag. Run matrix in GitHub Actions. |
| Negative test coverage | Tests that verify `fail` messages fire correctly for invalid input. Most charts only test happy paths. | MEDIUM | Partially exists. Expand: test every `fail`/`required` path, verify error messages are actionable. |

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem good but create problems. Deliberately do NOT build these.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Rearchitect as a library chart | bjw-s uses a library chart pattern. Seems cleaner. | Massive rewrite. Global-chart's value is in direct template rendering, not being consumed as a dependency. Library charts add indirection and require all consumers to create wrapper charts. | Keep as application chart. The multi-deployment map IS the abstraction layer. |
| StatefulSet / DaemonSet controller types | "My app needs StatefulSets." | Scope creep. StatefulSets have fundamentally different lifecycle (stable network IDs, ordered scaling, PVC management). Adding them doubles template complexity. DaemonSets are even more specialized. | Stay focused on Deployments + Jobs/CronJobs. Users needing StatefulSets should use a dedicated chart or raw manifests. |
| Operator-style CRD generation | "Let the chart create CRDs." | CRDs are cluster-scoped, have complex lifecycle (cannot be deleted by Helm uninstall), and conflict between releases. Helm explicitly recommends against managing CRDs in charts. | Support referencing existing CRDs (ExternalSecret) but do not generate CRD definitions. |
| Helm hooks for chart lifecycle (pre-install, pre-upgrade infra) | "Auto-create namespaces or PVCs before install." | Helm hooks are fragile, hard to debug, and create ordering issues. The chart already supports hook Jobs for application-level tasks (migrations). Adding infra hooks mixes concerns. | Keep hooks for application tasks only (migrations, seeding). Infra provisioning belongs in Terraform/Crossplane. |
| Built-in Istio/Linkerd sidecar injection | "Add service mesh annotations by default." | Service mesh config is cluster-specific and version-dependent. Baking in Istio annotations couples the chart to a specific mesh version. | Support arbitrary `podAnnotations` and `podLabels` -- users add mesh annotations there. Already supported. |
| `global.env` / global environment variables | "Set env vars once, apply to all deployments." | Implicit inheritance is confusing. Users forget they set a global var and wonder why a deployment behaves unexpectedly. Debugging is harder. | Each deployment declares its own env. Use Helm's `-f` layering to share values across deployments externally. |
| Kustomize-style patches / raw YAML injection | "Let me inject arbitrary YAML into any resource." | Bypasses all validation. Makes the chart's `fail` guards useless. Creates unmaintainable configurations that break on chart upgrades. | Support specific extension points (`extraVolumes`, `extraContainers`, `extraEnvs`) rather than raw injection. These are already partially supported. |

## Feature Dependencies

```
values.schema.json
    └──enhances──> Compile-time validation (existing fail guards)
    └──enables──> IDE autocomplete for values files

Kubeconform CI
    └──requires──> make generate-templates (existing)
    └──enhances──> Multi-K8s-version matrix

Secure securityContext defaults
    └──may-require──> values.schema.json (to validate securityContext structure)

CronJob SA inheritance fix
    └──requires──> Shared SA resolution helper (refactoring)
    └──part-of──> Hook/CronJob template deduplication

Multi-key ExternalSecret
    └──independent──> (no dependencies)

automountServiceAccountToken default change
    └──requires──> values.schema.json (to document the change clearly)
    └──conflicts-with──> RBAC roles that assume token is mounted
```

### Dependency Notes

- **values.schema.json enhances compile-time validation:** Schema catches type errors and enum violations; `fail` guards catch semantic errors. Together they cover all input validation.
- **Kubeconform requires generate-templates:** Kubeconform validates YAML files on disk, so the existing manifest generation step feeds it.
- **CronJob SA fix is part of template deduplication:** Fixing the SA asymmetry is simplest when extracting the shared helper, so do both together.
- **automountServiceAccountToken conflicts with RBAC assumptions:** Changing the default to `false` means RBAC-bound workloads must explicitly set `automount: true`. Document this in migration notes.

## MVP Definition

Since global-chart is already at v1.3.0 and in production use, "MVP" here means "minimum viable hardening milestone."

### Immediate Hardening (v1.4.0)

- [x] Fix CronJob SA inheritance asymmetry -- known bug, users will hit it
- [x] Fix configurable test-connection image -- blocks air-gapped adoption
- [x] Add secure-by-default securityContext in values.yaml -- clusters with PSS enforcement reject current defaults
- [x] Change `automountServiceAccountToken` default to `false` -- security hardening
- [x] Extend compile-time `fail` to validate hookType and restartPolicy enums -- prevents broken manifests

### Quality Gate (v1.5.0)

- [ ] Add `values.schema.json` -- the single highest-impact quality feature
- [ ] Add kubeconform validation to CI pipeline -- catches API deprecations
- [ ] Add negative test coverage for all `fail`/`required` paths -- proves validation works
- [ ] Multi-key ExternalSecret support -- unblocks common secret patterns
- [ ] Template deduplication (shared job pod spec helper) -- reduces divergence risk

### Future Hardening (v2.0.0)

- [ ] Remove legacy volume `.type` format -- breaking change, clean up tech debt
- [ ] RBAC positional naming fix (require explicit `name`) -- breaking change
- [ ] Multi-Kubernetes-version CI matrix -- forward compatibility assurance
- [ ] CHANGELOG automation -- ArtifactHub compliance

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| `values.schema.json` | HIGH | HIGH | P1 |
| CronJob SA inheritance fix | HIGH | LOW | P1 |
| Secure securityContext defaults | HIGH | MEDIUM | P1 |
| `automountServiceAccountToken: false` | HIGH | LOW | P1 |
| Configurable test-connection image | MEDIUM | LOW | P1 |
| hookType/restartPolicy enum validation | MEDIUM | LOW | P1 |
| Kubeconform in CI | HIGH | MEDIUM | P1 |
| Negative test coverage | HIGH | MEDIUM | P1 |
| Multi-key ExternalSecret | MEDIUM | LOW | P2 |
| Template deduplication (shared helper) | MEDIUM | MEDIUM | P2 |
| Multi-K8s-version CI matrix | MEDIUM | MEDIUM | P2 |
| CHANGELOG automation | LOW | LOW | P2 |
| Remove legacy volume format | LOW | LOW | P3 (v2.0) |
| RBAC positional naming fix | LOW | LOW | P3 (v2.0) |
| ClusterRole/ClusterRoleBinding support | LOW | MEDIUM | P3 |

**Priority key:**
- P1: Must have for hardening milestone -- security, correctness, or validation gaps
- P2: Should have -- quality improvements and DX enhancements
- P3: Future consideration -- breaking changes or low-urgency features

## Competitor Feature Analysis

| Feature | Bitnami Common | bjw-s Common Library | Stakater Application | global-chart (current) | global-chart (target) |
|---------|---------------|---------------------|---------------------|----------------------|----------------------|
| Multi-deployment per release | No | No | No | **Yes** | Yes |
| Job/CronJob inheritance | No | No | Basic | **Yes (with SA bug)** | Yes (fixed) |
| values.schema.json | Yes | Yes (sophisticated) | No | **No** | Yes |
| Secure securityContext defaults | Yes (runAsNonRoot) | Yes (configurable defaults) | Partial | **No (empty)** | Yes |
| automountServiceAccountToken | false by default | Configurable | true | **true** | false |
| Kubeconform / schema validation CI | Yes | Yes | No | **No** | Yes |
| Multi-K8s version testing | Yes | Yes | No | **No** | Yes |
| Compile-time fail guards | Some | No | No | **Yes (extensive)** | Extended |
| Negative tests | Some | Some | No | **Partial** | Comprehensive |
| ExternalSecret multi-key | N/A (different CRD) | N/A | N/A | **Single-key** | Multi-key |
| Library chart architecture | Yes (dependency) | Yes (library) | No (application) | **No (application)** | No (application) |
| Controller types (StatefulSet, DaemonSet) | Yes | Yes | Yes | **No (Deployment only)** | No (deliberate) |

## Sources

- [Helm Best Practices - Official Docs](https://helm.sh/docs/chart_best_practices/)
- [Schema Validation for Helm Charts](https://oneuptime.com/blog/post/2026-01-17-helm-schema-validation-values/view)
- [Bitnami Helm Charts](https://github.com/bitnami/charts)
- [Bitnami Best Practices for Hardening Helm Charts](https://docs.bitnami.com/tutorials/bitnami-best-practices-hardening-charts)
- [bjw-s Common Library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
- [Stakater Application Chart](https://github.com/stakater/application)
- [Helm Chart Testing Best Practices](https://alexandre-vazquez.com/helm-chart-testing-best-practices/)
- [Quality Gate for Helm Charts](https://medium.com/@michamarszaek/quality-gate-for-helm-charts-f260f5742198)
- [KubeLinter](https://github.com/stackrox/kube-linter)
- [Securing Helm Charts with Security Contexts](https://oneuptime.com/blog/post/2026-01-17-helm-security-contexts-network-policies/view)
- [Bitnami Non-Root Containers](https://docs.bitnami.com/kubernetes/faq/configuration/use-non-root/)

---
*Feature research for: Enterprise-grade reusable Helm chart (quality audit & hardening)*
*Researched: 2026-03-15*
