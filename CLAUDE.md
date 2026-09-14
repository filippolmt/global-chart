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
the real one, not the hook copy → deployment `command`/`args` rendered → the SA a
root-level `cronJobs` entry references exists in the cluster → every
Service `targetPort` resolved to a container port and got endpoints →
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

`make e2e` also runs in CI as its own job in `.github/workflows/helm-ci.yml`
(~2 min). Two things about it are deliberate and easy to undo by accident:

- Hook bodies **assert** their environment instead of echoing it — `echo` exits
  0 whatever the prereq copies contain, which would make the "hook Job
  succeeded" assertion vacuous.
- The endpoint assertions read the **EndpointSlice ports**, not just whether the
  Service exists. A Service whose `targetPort` names nothing is created happily
  and its pod reports `serving: true`; only `ports: null` on the slice reveals
  it. Asserting on the Service object alone would be vacuous in the same way.
- One `pre-install` hook carries `weight: "-5"`, which drives the derived prereq
  weights negative (-12 and -10). That is the only runtime coverage of the
  never-floor-at-0 rule in pattern 6 above: with a floor, the prereq ConfigMap
  sorts after the Job and the Job starts without it. Keep a negative-weight hook
  in the scenario.

Installing KEDA logs `Warning: unrecognized format "int32"` (and `int64`) three
times. It comes from KEDA's own CRDs — the ScaledJob schema embeds `batch/v1`
JobSpec, which carries 145 such formats — and Kubernetes warns on any format
outside its closed list while validating on `type: integer` regardless. Nothing
to fix here, and not worth filtering: suppressing it means swallowing the
install's stderr, which would hide real server warnings too.
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
| `_helpers.tpl` | Core naming, labels (`fullname`, `deploymentFullname`, `labels`, `selectorLabels`, `deploymentEnabled`, `serviceEnabled`, `deploymentServiceAccountName`, `hookLabelsWithComponent` — hook labels plus the component; pass `deploymentName` for a deployment-level hook, omit it for a root-level one). Job-family name helpers — single home for each name + its truncation constant, consumed by both resource templates and `validateNameCollisions`: `rootCronJobName`/`deploymentCronJobName` (trunc 52), `deploymentHookName` (canonical single trunc 63), `hookPrereqConfigName`/`hookPrereqSecretName` (trunc 63). Mounted-config-file name family, same idiom: `mountedConfigMapName` (`<deploymentFullname>-md-cm-<fileName>`, the ConfigMap for a `files` entry *and* for a `bundles[].files` entry — one name space, so `validateNameCollisions` fails when the two sides collide) and the two volume-name helpers `mountedFileVolumeName` / `mountedBundleVolumeName` (`md-cm-file-<name>` | `md-cm-bundle-<i>` — two helpers, not one taking a `kind`: they share no body and every call site passes a literal). Neither truncates: `values.schema.json` bounds `name` at 52 chars — 63 minus `len("md-cm-file-")` — because truncating would manufacture the very collision the validator catches |
| `_image-helpers.tpl` | `imageString` (string/map/global registry/numeric tags), `imagePullPolicy` |
| `_job-helpers.tpl` | `jobPodSpec` — the pod spec of **every** hook/cronjob, both scopes: one implementation, not three, so a new pod-level field is added once. Deployment-level callers pass `deploy` and get the full inheritance chain; root-level callers omit it and each field resolves to the job's own value (`imagePullSecrets` alone then falls back to `global`, as it always did — no field gains a global fallback). One `kind` param (`hook` | `cronjob`) selects the only two behaviours that differ — dnsConfig inheritance and initContainers — and **fails** on anything else; it is the job's kind, not its scope. `jobImageString` — unified image resolution (`image` > `deploy.image` > `fromDeployment` lookup+fail), `errCtx` param preserves exact failure messages. `jobServiceAccount` — unified SA resolution for **every** job scope (name/create/automount/annotations), returns JSON consumed via `fromJson`. Root-level jobs pass no `deploy`: that scope simply *is* the "no deployment SA applies" case, and falls out of the same resolution — so `hook.yaml`/`cronjob.yaml` PART 1 and PART 2 cannot drift apart again |
| `_hook-helpers.tpl` | `hookAnnotations(hookType · role · command \| weight)` — the three `helm.sh/hook*` annotations for one resource. `role` is `job` \| `sa` \| `prereq` \| `pre-install-sa` and is orthogonal to scope; it selects a row of a table (weight offset, default delete policy, whether the resource belongs to one hook) and nothing else. The roles a hook owns (`job`, `sa`) are called with that hook's `command`, so an explicit `deletePolicy` reaches them; the plumbing roles take a `weight` and **fail** if handed a command. An unknown role fails too — without that guard it silently takes offset 0 and renders a null delete policy, an invalid annotation the API server rejects far from its cause. `minHookWeight(hooks)` — minimum across a hooks map. `effectiveHookWeight(command)` — one command's weight; the only place the default of 10 and its `int` coercion live. See `docs/adr/0004-one-module-for-hook-lifecycle-annotations.md` |
| `_render-helpers.tpl` | `renderVolume` (native + legacy), `renderImagePullSecrets`, `renderDnsConfig`, `renderResources`, `renderCommonAnnotations`, `renderExternalSecretRemoteRef` (shared remoteRef block for data-list + single-key ExternalSecret branches). `renderConfigMapData` / `renderSecretData` — the `data:` **body** of a ConfigMap/Secret (the `key: value` lines at indent 0; the caller keeps its own `data:` key and applies `nindent 2`), shared by the real resource and its hook-prerequisite copy so the two cannot diverge. A map/slice ConfigMap value goes through `toYaml` into a **block scalar**: `ConfigMap.data` is `map[string]string`, and a nested mapping is a manifest the API server rejects. `containerPorts` — single source of truth for the pod side of the Service (see pattern 13), returns a JSON list consumed via `fromJsonArray`. `servicePrimaryPort` — single source of truth for the Service side of the primary port (see pattern 13): the four defaults `port` 80 / `name` http / `protocol` TCP / `targetPort` following the name, as JSON consumed via `fromJson` |
| `_keda-helpers.tpl` | `kedaTriggerAuthName` (trunc 63), `kedaAuthRefName` (resolves a trigger's `authenticationRef` against the `kedaTriggerAuthentications` map, passthrough when absent), `kedaTriggers` (trigger list with refs resolved), `requireKedaCrd` (fails when `keda.sh/v1alpha1` is not registered) |
| `_validate-helpers.tpl` | `validateNameCollisions` — fails on truncation-induced name collisions. Every check routes through `registerName` (kind · name · owner · optional hint), never an inline `hasKey`/`fail`/`set`: a kind's accumulator must hold **every** name of that kind whatever derived it, because collisions cross sources — `$cmNames` carries the deployment's own ConfigMap, its `md-cm` copies and its hook-prerequisite copy alike. `registerSAName` keeps its own wording (an SA is *created for* an owner) and does not delegate. `validateRoutingConflict` — ingress vs httpRoute. `validateAutoscalingConflict` — HPA vs KEDA per deployment. `validateServiceTargetPorts` — fails when a named `targetPort` matches no declared container port (see pattern 13) |

### Key Design Patterns

1. **Multi-deployment iteration**: `range $name, $deploy := .Values.deployments` — each deployment generates Deployment, Service, SA, ConfigMap, Secret, HPA, PDB, NetworkPolicy
2. **Naming**: `{release}-{chart}-{deploymentName}` (trunc 63). CronJobs trunc 52 (K8s adds 11-char timestamp)
3. **Selector labels**: `app.kubernetes.io/component: {deploymentName}` ensures pods don't overlap
4. **SA default**: `serviceAccount.create` defaults to `true`. Deployment-level hooks/cronjobs inherit the deployment SA via `hasKey/ternary` with default true
5. **Inheritance**: Deployment-level hooks/cronjobs inherit image, configMap, secret, SA, envFrom, imagePullSecrets, hostAliases, securityContext, dnsConfig (cronjobs only), nodeSelector, tolerations, affinity. Override with explicit value; use empty `{}` or `[]` to stop inheritance. Toggle `inheritDeploymentConfigMap: false` / `inheritDeploymentSecret: false` to break ConfigMap/Secret env injection without removing them from the deployment (defensive: limits secret leak surface for narrow-scope cronjobs/hooks)
   - **Not inheritable**: `command` / `args`. A deployment-level hook or cronjob never picks up its parent's entrypoint — a migration hook inheriting `python -m app.worker` would silently run the worker. Locked by regression tests in `hook_test.yaml` / `cronjob_test.yaml`
   - **Not inheritable**: `mountedConfigFiles`. The mounted files describe the *Deployment's* runtime, and one can carry credentials (`odoo.conf` holds the DB password) — handing them to every hook and cronjob of the deployment is the leak surface `inheritDeploymentSecret: false` exists to narrow, and a migration hook is not that runtime. A job that genuinely needs one declares its own `volumes` / `volumeMounts`; the generated ConfigMap name is **not** a public interface — do not hardcode `<release>-<chart>-<deploy>-md-cm-<name>` into values
   - **Asymmetry**: Root-level `.Values.cronJobs` and `.Values.hooks` do NOT auto-inherit anything from deployments — they are standalone. Reference deployment ConfigMaps/Secrets explicitly via `envFromConfigMaps` / `envFromSecrets` (or use `fromDeployment` for image only). Only `.Values.deployments.<name>.cronJobs` and `.Values.deployments.<name>.hooks` auto-inherit.
6. **Hook weight ordering**: the invariant `prereq ConfigMap/Secret < SA < Job` lives in the role table of `hookAnnotations` (`_hook-helpers.tpl`) — read the offsets there, and never recompute a weight or a delete policy inline. Derived weights are **never floored at 0** — Helm allows negative hook weights, and clamping a prereq to 0 would sort it *after* a Job whose weight is negative, which is the exact ordering failure the invariant exists to prevent
7. **Hook prerequisite resources** (*hook-prerequisite copies*): Deployment ConfigMap/Secret are duplicated as hook-annotated resources because normal resources aren't updated until after hooks complete. The deployment ServiceAccount gets the same treatment, but **only for `pre-install`** and with delete policy `hook-succeeded,hook-failed` instead of `before-hook-creation` — the copy shares the real SA's name and must be gone before Helm creates it. See `docs/adr/0002-hook-prerequisite-serviceaccount-copy.md` before touching it
8. **Hook resources clean themselves up**: hook resources are not part of the release manifest, so Helm never deletes them at uninstall. Plumbing (prereq ConfigMap/Secret, chart-created hook SAs) therefore defaults to `before-hook-creation,hook-succeeded` — the prereq Secret in particular holds the deployment's secret data and must not survive the release. Hook **Jobs** keep the plain `before-hook-creation` default on purpose: a completed hook Job is the record of what ran. An explicit `deletePolicy` on the hook is honoured by the resources the hook owns — its **Job** (role `job`) and the SA the chart creates for it (role `sa`). The plumbing copies have a **fixed** policy per role: the prereq ConfigMap/Secret are shared by every hook of the deployment, so an explicit policy would have no owner, and the `pre-install` ServiceAccount copy is pinned to `hook-succeeded,hook-failed` (ADR 0002)
9. **Global fallback chains**: job > deployment > global, using `hasKey` at every level. Explicit `[]` stops fallback
10. **Schema**: `values.schema.json` validates during install/upgrade/lint. Does NOT use `required` on `mountedConfigFiles` items (templates handle runtime validation to allow `failedTemplate` tests)
11. **Autoscaling is either/or**: `deployments.<name>.autoscaling` (chart-rendered HPA) and `deployments.<name>.keda` (ScaledObject) are mutually exclusive per deployment — KEDA owns its own *derived HPA*. Either one enabled means the Deployment omits `spec.replicas` entirely; see `docs/adr/0003-keda-alongside-hpa.md`. `.Capabilities.APIVersions` carries CRDs only during a real install/upgrade, so anything rendering a KEDA scenario offline needs `--api-versions keda.sh/v1alpha1` (`HELM_API_VERSIONS` in the Makefile; `capabilities.apiVersions` in the unit-test suites). `helm lint` neither evaluates template `fail` nor accepts the flag, so `lint-chart` needs nothing — it just logs the `fail` message at INFO level and passes
12. **No `appVersion`**: this is a generic chart with no app version to pin. `app.kubernetes.io/version` is emitted only when set — guarded with `{{- with .Chart.AppVersion }}` in the label helpers; consumers set it via `global.commonLabels`. Pod/Service selectors never included it.
13. **The primary port has one source per side**: `servicePrimaryPort` owns the Service side — the four defaults (`port`, `name`, `protocol`, `targetPort`) that `service.yaml`, `containerPorts`, `validateServiceTargetPorts`, `resolveBackend` and `tests/test-connection.yaml` all consume (`NOTES.txt` shares only `serviceEnabled`). `containerPorts` owns the pod side, deriving the container's ports from that tuple and from `deployments.<name>.service.extraPorts`; Never re-derive one of those defaults inline. Two things stay out of the tuple on purpose: the container port itself (`kindIs "string" $targetPort | ternary $port $targetPort`) is the pod side and lives in `containerPorts`; and `resolveBackend`'s *other* `80`, the one for an explicit `ref.service`, belongs to an arbitrary Service the chart does not create — it only coincides with the primary port's default. `extraPorts` entries share no default (`name`/`port`/`targetPort` are all `required` in the schema), so they are not in the tuple either. `deployment.yaml` renders it and `validateServiceTargetPorts` checks named targetPorts against it. Never compute a container port anywhere else — a Service targeting a port name nothing declares is created happily by Kubernetes and simply has no endpoints, so the failure appears at request time, far from its cause. Three separate bugs came from `deployment.yaml` and `service.yaml` each deriving ports on their own (issue #82). A numeric `targetPort` **is** the container's port; a named one must resolve to a declared port, or the render fails. Entries dedupe by name and by number+protocol — never by number alone, since TCP and UDP on one number are two ports.

### Resource Naming Limits

| Resource | Max |
|----------|-----|
| Most resources | 63 chars |
| CronJobs | **52 chars** |
| Hook prerequisite ConfigMap/Secret | 63 chars (name includes `-hook-config`/`-hook-secret` suffix) |
| `mountedConfigFiles` `name` (both branches) | **52 chars**, DNS-1123 label, enforced by `values.schema.json` — it feeds the pod volume name `md-cm-file-<name>`, and a volume name is a DNS-1123 *label* capped at 63 |
| Mounted config file ConfigMap | 253 chars — `mountedConfigMapName` deliberately does **not** truncate: a ConfigMap name is a DNS *subdomain*, so `<deploymentFullname>-md-cm-<name>` has room the volume does not. Truncating would manufacture the collision `validateNameCollisions` exists to catch |

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

**Adding a hook role:** Add a row to the table in `hookAnnotations` (`_hook-helpers.tpl`), never a new weight or delete-policy derivation at the call site. The row is the enforcement: the two `fail` guards beside it exist because a missing row renders a null annotation instead of stopping

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
