# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Global-chart is a reusable Helm chart providing multi-deployment Kubernetes building blocks. See `Chart.yaml` for the current version, `README.md` for the full feature list and examples, `CHANGELOG.md` for version history and migration guides.

## Commands

```bash
make all                    # Full pipeline: lint + test + bad-values + generate + kubeconform + kube-linter
make lint-chart             # Lint every scenario in TEST_CASES (Makefile)
make unit-test              # Run helm-unittest suites via Docker
make validate-bad-values    # Verify schema rejects invalid values
make kubeconform            # Validate manifests against K8s 1.29
make kube-linter            # Lint manifests (addAllBuiltIn)
make generate-docs          # Regenerate helm-docs README
make render VALUES=tests/test01/values.01.yaml TEMPLATE=deployment.yaml  # Debug single template
make e2e                    # Install/upgrade/uninstall on a throwaway kind cluster
make kind-delete            # Tear the e2e cluster down
```

Always run `make lint-chart` and `make unit-test` after modifying templates or values.

### Install tests — always via `make e2e`, never a hand-rolled `helm install`

`helm-unittest` renders YAML; it cannot see the *runtime* half of this chart —
hook ordering, hook-weight sorting, `hook-delete-policy` cleanup, whether a
resource exists at the moment a hook Job schedules. Anything touching
`hook.yaml`, hook weights, delete policies or ServiceAccount lifecycle needs
`make e2e`.

`make e2e` downloads `kind` into `.bin/` (gitignored), creates a throwaway
cluster, installs KEDA (operator + CRDs, `kind-keda`) so the whole autoscaling
chain is exercised for real, installs `tests/e2e/values.yaml`, then asserts:
release deployed →
pre-install hook Job succeeded under the chart-created SA → the surviving SA is
the real one, not the hook copy → deployment `command`/`args` rendered →
ScaledObject/TriggerAuthentication applied with the `authenticationRef` resolved
→ KEDA marked the ScaledObject `Ready` and created the derived HPA with the
rendered bounds → the `cron` trigger actually scaled the Deployment to its
`desiredReplicas` → upgrade kept the SA UID → upgrade did **not** reset
`spec.replicas` on the KEDA-scaled Deployment → uninstall leaves no orphaned
ConfigMap/Secret/ServiceAccount/ScaledObject/TriggerAuthentication, and the
derived HPA is garbage-collected with its ScaledObject.

The `cron` trigger is deliberate: no network, no external metric source. Its
window is 00:00–23:59 UTC, so a run started in the one blind minute before
midnight UTC will fail the scale assertion.
Extend `tests/e2e/values.yaml` and the assertion block in the `e2e` target when
adding runtime behaviour.

**Never run `helm install` against whatever `kubectl` context happens to be
selected** — it can be production. `make e2e` pins `KUBECONFIG` to
`.bin/kind-kubeconfig` and can only ever reach its own kind cluster; keep it
that way. The target also repoints the API server at the control-plane
container's address when it runs inside a container, where the kubeconfig's
`127.0.0.1` is the Docker host rather than the caller.
When schema or user-visible values change (new fields, defaults, descriptions), also run `make generate-docs` to refresh `charts/global-chart/README.md`.

## Architecture

### File Layout

- `charts/global-chart/templates/` — Helm templates
- `charts/global-chart/templates/_*.tpl` — Helper files (domain-split, see below)
- `charts/global-chart/values.schema.json` — JSON Schema Draft 7
- `charts/global-chart/tests/` — helm-unittest suites (one `*_test.yaml` per template)
- `tests/` — Lint scenario values + `bad-values/` for schema rejection tests

### Helper Files

| File | Domain |
|------|--------|
| `_helpers.tpl` | Core naming, labels (`fullname`, `deploymentFullname`, `labels`, `selectorLabels`, `deploymentEnabled`, `deploymentServiceAccountName`). Job-family name helpers — single home for each name + its truncation constant, consumed by both resource templates and `validateNameCollisions`: `rootCronJobName`/`deploymentCronJobName` (trunc 52), `deploymentHookName` (canonical single trunc 63), `hookPrereqConfigName`/`hookPrereqSecretName` (trunc 63) |
| `_image-helpers.tpl` | `imageString` (string/map/global registry/numeric tags), `imagePullPolicy` |
| `_job-helpers.tpl` | `inheritedJobPodSpec` — shared pod spec for deployment-level hooks/cronjobs with full inheritance chain. Params: `inheritDnsConfig` (true=cronjob, false=hook), `renderInitContainers` (true=cronjob, false=hook). `jobImageString` — unified image resolution (`image` > `deploy.image` > `fromDeployment` lookup+fail), `errCtx` param preserves exact failure messages. `jobServiceAccount` — unified deployment-level SA resolution (name/create/automount/annotations), returns JSON consumed via `fromJson` |
| `_render-helpers.tpl` | `renderVolume` (native + legacy), `renderImagePullSecrets`, `renderDnsConfig`, `renderResources`, `renderCommonAnnotations`, `renderExternalSecretRemoteRef` (shared remoteRef block for data-list + single-key ExternalSecret branches) |
| `_keda-helpers.tpl` | `kedaTriggerAuthName` (trunc 63), `kedaAuthRefName` (resolves a trigger's `authenticationRef` against the `kedaTriggerAuthentications` map, passthrough when absent), `kedaTriggers` (trigger list with refs resolved), `requireKedaCrd` (fails when `keda.sh/v1alpha1` is not registered) |
| `_validate-helpers.tpl` | `validateNameCollisions` — fails on truncation-induced name collisions. `validateRoutingConflict` — ingress vs httpRoute. `validateAutoscalingConflict` — HPA vs KEDA per deployment |

### Key Design Patterns

1. **Multi-deployment iteration**: `range $name, $deploy := .Values.deployments` — each deployment generates Deployment, Service, SA, ConfigMap, Secret, HPA, PDB, NetworkPolicy
2. **Naming**: `{release}-{chart}-{deploymentName}` (trunc 63). CronJobs trunc 52 (K8s adds 11-char timestamp)
3. **Selector labels**: `app.kubernetes.io/component: {deploymentName}` ensures pods don't overlap
4. **SA default**: `serviceAccount.create` defaults to `true`. Deployment-level hooks/cronjobs inherit the deployment SA via `hasKey/ternary` with default true
5. **Inheritance**: Deployment-level hooks/cronjobs inherit image, configMap, secret, SA, envFrom, imagePullSecrets, hostAliases, securityContext, dnsConfig (cronjobs only), nodeSelector, tolerations, affinity. Override with explicit value; use empty `{}` or `[]` to stop inheritance. Toggle `inheritDeploymentConfigMap: false` / `inheritDeploymentSecret: false` to break ConfigMap/Secret env injection without removing them from the deployment (defensive: limits secret leak surface for narrow-scope cronjobs/hooks)
   - **Not inheritable**: `command` / `args`. A deployment-level hook or cronjob never picks up its parent's entrypoint — a migration hook inheriting `python -m app.worker` would silently run the worker. Locked by regression tests in `hook_test.yaml` / `cronjob_test.yaml`
   - **Asymmetry**: Root-level `.Values.cronJobs` and `.Values.hooks` do NOT auto-inherit anything from deployments — they are standalone. Reference deployment ConfigMaps/Secrets explicitly via `envFromConfigMaps` / `envFromSecrets` (or use `fromDeployment` for image only). Only `.Values.deployments.<name>.cronJobs` and `.Values.deployments.<name>.hooks` auto-inherit.
6. **Hook weight ordering**: `prereq ConfigMap/Secret (w-7) < SA (w-5) < Job (w)`, derived from effective Job weight (default 10). `minJobWeight` across all hooks per deployment determines prereq weight. Derived weights are **never floored at 0** — Helm allows negative hook weights, and clamping a prereq to 0 would sort it *after* a Job whose weight is negative, which is the exact ordering failure the invariant exists to prevent
7. **Hook prerequisite resources** (*hook-prerequisite copies*): Deployment ConfigMap/Secret are duplicated as hook-annotated resources because normal resources aren't updated until after hooks complete. The deployment ServiceAccount gets the same treatment, but **only for `pre-install`** and with delete policy `hook-succeeded,hook-failed` instead of `before-hook-creation` — the copy shares the real SA's name and must be gone before Helm creates it. See `docs/adr/0002-hook-prerequisite-serviceaccount-copy.md` before touching it
8. **Hook resources clean themselves up**: hook resources are not part of the release manifest, so Helm never deletes them at uninstall. Plumbing (prereq ConfigMap/Secret, chart-created hook SAs) therefore defaults to `before-hook-creation,hook-succeeded` — the prereq Secret in particular holds the deployment's secret data and must not survive the release. Hook **Jobs** keep the plain `before-hook-creation` default on purpose: a completed hook Job is the record of what ran. All of them still honour an explicit `deletePolicy` on the hook
9. **Global fallback chains**: job > deployment > global, using `hasKey` at every level. Explicit `[]` stops fallback
10. **Schema**: `values.schema.json` validates during install/upgrade/lint. Does NOT use `required` on `mountedConfigFiles` items (templates handle runtime validation to allow `failedTemplate` tests)
11. **Autoscaling is either/or**: `deployments.<name>.autoscaling` (chart-rendered HPA) and `deployments.<name>.keda` (ScaledObject) are mutually exclusive per deployment — KEDA owns its own *derived HPA*. Either one enabled means the Deployment omits `spec.replicas` entirely; see `docs/adr/0003-keda-alongside-hpa.md`. `.Capabilities.APIVersions` carries CRDs only during a real install/upgrade, so anything rendering a KEDA scenario offline needs `--api-versions keda.sh/v1alpha1` (`HELM_API_VERSIONS` in the Makefile; `capabilities.apiVersions` in the unit-test suites). `helm lint` neither evaluates template `fail` nor accepts the flag, so `lint-chart` needs nothing — it just logs the `fail` message at INFO level and passes
12. **No `appVersion`**: this is a generic chart with no app version to pin. `app.kubernetes.io/version` is emitted only when set — guarded with `{{- with .Chart.AppVersion }}` in the label helpers; consumers set it via `global.commonLabels`. Pod/Service selectors never included it.

### Resource Naming Limits

| Resource | Max |
|----------|-----|
| Most resources | 63 chars |
| CronJobs | **52 chars** |
| Hook prerequisite ConfigMap/Secret | 63 chars (name includes `-hook-config`/`-hook-secret` suffix) |

## Template Coding Rules

These are the hard-won patterns from this codebase. Violating them causes subtle bugs.

**Boolean/numeric fields — never use `default`:**
```yaml
# WRONG: default true $var replaces false with true
enabled: {{ default true $deploy.enabled }}
# CORRECT:
enabled: {{ hasKey $deploy "enabled" | ternary $deploy.enabled true }}
```

**Inheritance — use `hasKey` to distinguish "not set" from "empty":**
```yaml
# WRONG: {} and [] are falsy, incorrectly inherits
{{- if not $job.field }}{{ $deploy.field }}{{- end }}
# CORRECT:
{{ hasKey $job "field" | ternary $job.field $deploy.field }}
```

**Never mutate `.Values`:**
```yaml
# WRONG:
{{- $_ := set $ing.annotations "key" "value" }}
# CORRECT:
{{- $annotations := deepCopy $ing.annotations }}
```

**Nil-safe nested access:**
```yaml
{{- $service := default (dict) $deploy.service }}
```

**Shared helpers that can return empty — wrap with `{{- with }}`:**
```yaml
{{- with (include "global-chart.renderFoo" $arg) }}{{- . | nindent N }}{{- end }}
```

**Shared helpers — use `-}}` trim before literal content:**
```yaml
{{- with . -}}
imagePullSecrets:
```

**Schema ↔ Template consistency:**
- Every field a template accesses must be declared in the schema
- Every schema field must be used by a template
- Run `make lint-chart` to verify schema doesn't reject valid test values

**Adding new helpers:** Place in the appropriate domain file, not `_helpers.tpl`

**Adding `merge` on `.Values` maps:** Always `deepCopy` the first argument

**Adding hook weight logic:** Maintain invariant `prereq (w-7) < SA (w-5) < Job (w)`

**Every template must have a corresponding `*_test.yaml`** in `charts/global-chart/tests/`

## Agent skills

`CONTEXT.md` (glossario di dominio) e `docs/agents/` sono gitignorati: esistono
solo sulla macchina di chi sviluppa, non nel repo. I riferimenti qui sotto
funzionano in locale; se i file non ci sono, salta la sezione. `docs/adr/`
invece è tracciato — è linkato da `CHANGELOG.md` e da `hook.yaml`.

### Issue tracker

Issues e PRD su GitHub Issues (`filippolmt/global-chart`), via `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Cinque ruoli canonici, label = nome del ruolo (default). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` alla root. See `docs/agents/domain.md`.
