# CLAUDE.md

Global-chart is a reusable Helm chart providing multi-deployment Kubernetes
building blocks. `README.md` — feature list and examples. `CHANGELOG.md` —
version history and migration guides. `docs/adr/` — the decisions behind the
rules below.

## Commands

```bash
make all                    # lint + test + bad-values + docs + kubeconform + kube-linter
make lint-chart             # lint every scenario in TEST_CASES
make unit-test              # helm-unittest suites via Docker
make generate-docs          # regenerate the helm-docs README
make e2e                    # install/upgrade/uninstall on a throwaway kind cluster
make render VALUES=tests/test01/values.01.yaml TEMPLATE=deployment.yaml
```

The Makefile carries the rest. Three rules about when to run what:

- Templates or values changed → `make lint-chart` and `make unit-test`.
- Schema or user-visible values changed (new fields, defaults, descriptions) →
  also `make generate-docs`, to refresh `charts/global-chart/README.md`.
- Runtime behaviour touched — `hook.yaml`, hook weights, delete policies,
  ServiceAccount lifecycle → `make e2e`. It is the only thing that sees the
  runtime half of the chart; `helm-unittest` only renders YAML. What it asserts,
  what in it is deliberate, and why a hand-rolled `helm install` is forbidden:
  `tests/e2e/README.md`.

## Architecture

### File Layout

- `charts/global-chart/templates/` — Helm templates; `_*.tpl` are the
  domain-split helpers below
- `charts/global-chart/values.schema.json` — JSON Schema
- `charts/global-chart/tests/` — helm-unittest suites, one `*_test.yaml` per
  template
- `tests/` — lint scenario values + `bad-values/` for rejection tests, split into
  `schema/` (rejected by `values.schema.json`) and `fail/` (rejected by a
  template `fail`). The directory *is* the declaration and `validate-bad-values`
  asserts it, so a schema hole covered by a `fail` cannot pass as coverage.
  Every `fail/` fixture carries one or more `# Expected fail substring: "…"`
  lines, and each must appear in the error: a fixture rejected by the wrong
  `fail` does not pass

### Helper Files

**Every helper opens with a header comment carrying its own rules, its
rationale and its ADR link. Read that header before editing the domain** — it
is the source of truth, this table is only the routing.

| File | Domain |
|------|--------|
| `_helpers.tpl` | Naming and labels. `truncName` is the single home of the truncation trim; `mergeLabels` is the single home of the label precedence; the Job-family, mounted-config-file and hook-copy name helpers (`rbacs.roles` and every release-created ServiceAccount) are the single home of each generated name and its truncation constant |
| `_image-helpers.tpl` | `imageString`, `imagePullPolicy` |
| `_job-helpers.tpl` | One implementation of the pod spec, image resolution, the CronJob spec fields (`cronJobSpecFields`) and the Job spec fields table (`jobSpecVerbatimFields`) for **every** hook and cronjob, both scopes — root-level callers simply pass no `deploy`. `jobValuesPath` is the single home of the name a job carries in error messages |
| `_serviceaccount-helpers.tpl` | Every ServiceAccount the chart renders or binds, resolved to `{create, name, automount, annotations}`: deployment, rbac and job resolvers, with the deployment and rbac defaults in `resolveServiceAccount`; the job resolver keeps its own chain, and rejects a job naming its SA twice with different names itself — every job render path goes through it, so the check cannot be skipped. Also the SA side of the hook copies (ADR 0010, 0011): every SA the release creates (`releaseServiceAccounts`), whether it creates one (`releaseCreatesServiceAccount`), the SA a copy binds (`serviceAccountCopyName`), the match of a hook to the SA copy (`hookReadsServiceAccountCopy`) and to the `rbacs.roles` copies (`hookRbacCopy`, over `rbacServiceAccounts`), and the SA a hook's pod runs as (`hookServiceAccountName`). Templates never read `serviceAccount.*` from values |
| `_hook-helpers.tpl` | The three `helm.sh/hook*` annotations, weights and delete policies, driven by a role table; the phase cut `hookReadsPrereqCopy`, the one enumeration of the hooks it admits (`prereqCopyHooks`) and the consumer scans of the ExternalSecret, `rbacs.roles` and ServiceAccount hook copies |
| `_render-helpers.tpl` | `printScalar`, the single home of how a number from values is printed, in integer and string fields alike; shared render blocks, `renderAnnotations`, the ConfigMap/Secret `data:` bodies and the Role `rules:` block shared with the hook-prerequisite copies, and the port helpers (`containerPorts`, `servicePrimaryPort`, `extraPortProtocol`, `serviceType`) |
| `_keda-helpers.tpl` | KEDA names, trigger and `authenticationRef` resolution, the CRD guard |
| `_validate-helpers.tpl` | The fullname against the labels it leads, name collisions, routing and autoscaling conflicts, named-`targetPort` resolution (`validateServiceTargetPorts`), the Service-side port constraints (`validateServicePorts`: duplicate port names and port+protocol pairs, `nodePort` only on NodePort/LoadBalancer). Also `hpaActiveTargets`, the single home of "an HPA target is active", read by the autoscaling validator and by `hpa.yaml` |

### Key Design Patterns

1. **Multi-deployment iteration**: `range $name, $deploy := .Values.deployments`
   — each deployment generates Deployment, Service, SA, ConfigMap, Secret, HPA,
   PDB, NetworkPolicy
2. **Naming**: `{release}-{chart}-{deploymentName}`
3. **Selector labels**: `app.kubernetes.io/component: {deploymentName}` ensures
   pods don't overlap
4. **SA default**: `serviceAccount.create` defaults to `true`. Deployment-level
   hooks/cronjobs inherit the deployment SA, default true
5. **Inheritance**: Deployment-level hooks/cronjobs inherit image, configMap,
   secret, SA, envFrom, `externalSecrets`, imagePullSecrets, hostAliases,
   securityContext, dnsConfig (cronjobs only), nodeSelector, tolerations,
   affinity. Override with an
   explicit value; use empty `{}` or `[]` to stop inheritance — except the
   `envFrom` lists, which are **additive**: a job's `envFromConfigMaps` /
   `envFromSecrets` (`[]` included) come after the deployment's and never
   replace them. The opt-outs are toggles instead, all default `true`:
   `inheritDeploymentConfigMap: false` / `inheritDeploymentSecret: false`
   break the generated ConfigMap/Secret env injection without removing them
   from the deployment, and `inheritDeploymentEnvFromConfigMaps: false` /
   `inheritDeploymentEnvFromSecrets: false` drop the deployment's
   `envFromConfigMaps` / `envFromSecrets` (issue #159). Defensive: they limit
   the secret leak surface for narrow-scope cronjobs/hooks. `externalSecrets`
   is not an `envFrom` list here: a job's own replaces the inherited one
   - **Not inheritable**: `command` / `args`. A deployment-level hook or cronjob
     never picks up its parent's entrypoint — a migration hook inheriting
     `python -m app.worker` would silently run the worker. Locked by regression
     tests in `hook_test.yaml` / `cronjob_test.yaml`
   - **Not inheritable**: `mountedConfigFiles`. The mounted files describe the
     *Deployment's* runtime, and one can carry credentials (`odoo.conf` holds the
     DB password) — handing them to every hook and cronjob is the leak surface
     `inheritDeploymentSecret: false` exists to narrow, and a migration hook is
     not that runtime. A job that genuinely needs one declares its own `volumes`
     / `volumeMounts`; the generated ConfigMap name is **not** a public
     interface — do not hardcode it into values
   - **`envFrom` order is a rule, not a rendering detail** — the last source wins
     on a shared key. A Deployment orders **by type**: every non-secret source,
     then every secret one, so a secret always beats a plaintext configuration. A
     job orders **by proximity**: everything the deployment hands it, then
     everything it declares itself, so the nearest declarer wins. The two are not
     reconcilable — a job has one level the Deployment does not, its own, and
     ordering it by type would make it lose to a source that is not its — and
     they differ on exactly one pair: the deployment's generated Secret against
     its `envFromConfigMaps`. Fixed by an `equal` on the whole list in
     `deployment_test.yaml` and `cronjob_test.yaml`; `contains` passes whatever
     the order, which is how the two ends drifted unobserved. See *Sorgente
     d'ambiente* in `CONTEXT.md`
   - **Asymmetry**: root-level `.Values.cronJobs` and `.Values.hooks` inherit
     nothing — they are standalone. Reference deployment ConfigMaps/Secrets
     explicitly via `envFromConfigMaps` / `envFromSecrets` (or `fromDeployment`
     for the image only). Only `.Values.deployments.<name>.cronJobs` and
     `.Values.deployments.<name>.hooks` auto-inherit
6. **Hook weight ordering**: the invariant `prereq ConfigMap/Secret < SA < Job`
   lives in the role table of `hookAnnotations` (`_hook-helpers.tpl`) — read the
   offsets there, and never recompute a weight or a delete policy inline.
   Derived weights are **never floored at 0** — Helm allows negative hook
   weights, and clamping a prereq to 0 would sort it *after* a Job whose weight
   is negative, the exact ordering failure the invariant exists to prevent
7. **Hook prerequisite copies**: the deployment ConfigMap/Secret are duplicated
   as hook-annotated resources, because normal resources are not updated until
   after hooks complete. A ServiceAccount the release creates (a deployment's,
   an `rbacs.roles` entry's or a cronjob's) gets a copy `<sa>-hook` for every
   hook of either scope bound to it in a `hookReadsPrereqCopy` phase, and the
   hook's pod runs as the copy — **never** under the real name: under Argo CD
   `pre-install` runs on every sync, and a same-name copy's deletion takes the
   live SA with it. The scan is `releaseServiceAccounts`, the match
   `hookReadsServiceAccountCopy`, the name `serviceAccountCopyName`, and
   hook.yaml is the one emitter, whoever creates the SA. Read
   `docs/adr/0011-hook-prerequisite-serviceaccount-copy-own-name.md` before
   touching it.
   An ExternalSecret a `pre-*` or `post-delete` hook references (`externalSecrets: [{name: <key>}]`,
   the phase cut in `hookReadsPrereqCopy` — not `pre-delete`, which runs before
   anything is deleted)
   gets a copy too, keyed by ExternalSecret rather than by deployment, under its
   **own** target `<target>-hook` — sharing the real target is `ErrSecretIsOwned`,
   and the copy's deletion would garbage-collect the live Secret. Its spec comes
   from `renderExternalSecretSpec`, the same helper as the real one. Read
   `docs/adr/0007-hook-prerequisite-externalsecret-copy.md` before touching it.
   An `rbacs.roles` entry whose SA such a hook runs as gets a copy as well: Role
   `<role>-hook` and RoleBinding `<binding>-hook`, bound to the SA copy when the
   release creates the SA (the SA copy above). The match is
   `hookRbacCopy`, the SA choice `serviceAccountCopyName`, the Role's rules
   `renderRoleRules`; each is a single home, read by rbac.yaml, hook.yaml and
   the validator alike. Own names for the same Argo CD reason. Read `docs/adr/0010-hook-prerequisite-rbac-copy.md`
   before touching it
8. **Hook resources clean themselves up**: hook resources are not part of the
   release manifest, so Helm never deletes them at uninstall. The plumbing
   (prereq ConfigMap/Secret, chart-created hook SAs) therefore deletes itself —
   the prereq Secret in particular holds the deployment's secret data and must
   not survive the release. Hook **Jobs** keep the plain `before-hook-creation`
   default on purpose: a completed hook Job is the record of what ran. An
   explicit `deletePolicy` on the hook reaches the resources the hook owns, its
   Job and its SA; the plumbing copies have a fixed policy per role, because a
   copy shared by every hook of the deployment would have no owner to take it
   from
9. **Global fallback chains**: job > deployment > global, using `hasKey` at
   every level. Explicit `[]` stops the fallback
10. **Schema**: `values.schema.json` validates during install/upgrade/lint. It
    does NOT use `required` on `mountedConfigFiles` items (templates handle that
    at runtime, so `failedTemplate` tests stay possible). A `$defs` that declares
    its properties is **closed**; one that passes a Kubernetes surface through
    stays open until we decide how much to admit — see
    `docs/adr/0006-close-the-schema-defs-that-declare-their-properties.md`. The
    job composites close with `unevaluatedProperties: false` (Helm >= 3.18.6;
    below it, ignored in silence), the flat ones with
    `additionalProperties: false`. The `allOf` branches (`jobCommon`,
    `cronJobSpec`, `hookJobSpec`, `rootJobSpec`, `deploymentJobSpec`) must
    **never** be closed: a branch validates the whole object alone, so closing
    one rejects every key the others contribute. **Every closed `$defs` carries
    its own fixture** in `tests/bad-values/schema/`, linked by a
    `# covers: <defsName>` line and enforced by
    `tests/bad-values/check-closure-coverage.py`: one file per definition,
    because one file with many typos is rejected by the first closure that holds
    and the rest go back to being invisible. Name the file after the scope and
    kind the values use (`root-cronjob-`, `deployment-hook-`), not after the
    `$defs` identifier — the `# covers:` line is what ties the two together.
    A map key that becomes part of a name (`deployments`, `cronJobs`, `hooks`
    and its types, `externalSecrets`, `kedaTriggerAuthentications`, both
    scopes) is constrained by `propertyNames` to what the tightest place it
    lands in accepts — a new such map needs one too, with its own fixture. A
    list field that identifies its entry and becomes a name is held to the same
    rule, by a `$ref` on the field: `rbacs.roles[].name` (ADR 0008). See
    *Chiave nominante* in `CONTEXT.md`
11. **Autoscaling is either/or**: `deployments.<name>.autoscaling` (a
    chart-rendered HPA) and `deployments.<name>.keda` (a ScaledObject) are
    mutually exclusive per deployment — KEDA owns its own *derived HPA*. Either
    one enabled means the Deployment omits `spec.replicas` entirely; see
    `docs/adr/0003-keda-alongside-hpa.md`. `.Capabilities.APIVersions` carries
    CRDs only during a real install/upgrade, so anything rendering a KEDA
    scenario offline needs `--api-versions keda.sh/v1alpha1`
    (`HELM_API_VERSIONS` in the Makefile; `capabilities.apiVersions` in the
    unit-test suites). `helm lint` neither evaluates a template `fail` nor
    accepts the flag, so `lint-chart` needs nothing — it logs the `fail` message
    at INFO level and passes
12. **No `appVersion`**: a generic chart has no app version to pin.
    `app.kubernetes.io/version` is emitted only when set; consumers set it via
    `global.commonLabels`. Pod/Service selectors never included it
13. **The primary port has one source per side**: `servicePrimaryPort` owns the
    Service side, `containerPorts` owns the pod side. Every consumer —
    `service.yaml`, `deployment.yaml`, `validateServiceTargetPorts`,
    `validateServicePorts`, `resolveBackend`, `tests/test-connection.yaml` —
    reads one of the two; the rules and the deduplication live in their header
    comments in `_render-helpers.tpl`. An extra port's protocol default and the
    Service type default have their own homes beside them,
    `extraPortProtocol` and `serviceType`. **Never derive a port or one of its defaults inline.**
    A Service targeting a port name nothing declares is created happily by
    Kubernetes and simply has no endpoints, so the failure appears at request
    time, far from its cause. Three separate bugs came from `deployment.yaml` and
    `service.yaml` each deriving ports on their own (issue #82)

### Resource Naming Limits

Kubernetes caps a name at 63 characters, so most resources truncate there. Three
exceptions, each owned by a name helper in `_helpers.tpl`:

| Resource | Limit |
|----------|-------|
| CronJobs | 52 — Kubernetes appends an 11-char timestamp to the Job it creates |
| `mountedConfigFiles` `name` | 52, DNS-1123 label, enforced by `values.schema.json` — it feeds the pod volume name, and a volume name is a DNS-1123 *label* |
| Mounted config file ConfigMap | Not truncated at all: a ConfigMap name is a DNS *subdomain*, so it has room the volume does not. Truncating would manufacture the collision `validateNameCollisions` exists to catch |

## Template Coding Rules

Hard-won. Violating them causes subtle bugs.

**Boolean/numeric fields — never use `default`:**
```yaml
# WRONG: default true $var replaces false with true
enabled: {{ default true $deploy.enabled }}
# CORRECT:
enabled: {{ hasKey $deploy "enabled" | ternary $deploy.enabled true }}
```

**Numbers from values — never print them bare, never `toString` / `%v` them:**
```yaml
# WRONG: a values-file number is a float64; 10000000 renders as 1e+07
terminationGracePeriodSeconds: {{ $deploy.terminationGracePeriodSeconds }}
LIMIT: {{ toString $value | quote }}
# CORRECT: whole numbers print as digits, 1.5 stays 1.5, strings pass through
terminationGracePeriodSeconds: {{ include "global-chart.printScalar" $deploy.terminationGracePeriodSeconds }}
LIMIT: {{ include "global-chart.printScalar" $value | quote }}
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
- Run `make lint-chart` to verify the schema doesn't reject valid test values

**Adding a new helper:** place it in the appropriate domain file, not
`_helpers.tpl`, and give it a header comment carrying its rules — that header is
where the next reader looks

**Adding `merge` on `.Values` maps:** always `deepCopy` the first argument

**Adding a hook role:** add a row to the table in `hookAnnotations`
(`_hook-helpers.tpl`), never a new weight or delete-policy derivation at the call
site. The row is the enforcement: the two `fail` guards beside it exist because a
missing row renders a null annotation instead of stopping

**Every template must have a corresponding `*_test.yaml`** in
`charts/global-chart/tests/`

## Agent skills

`CONTEXT.md` (glossario di dominio) e `docs/agents/` sono gitignorati: esistono
solo sulla macchina di chi sviluppa, non nel repo. I riferimenti qui sotto
funzionano in locale; se i file non ci sono, salta la sezione. `docs/adr/` invece
è tracciato — è linkato da `CHANGELOG.md` e da `hook.yaml`.

- **Issue tracker** — issues e PRD su GitHub Issues (`filippolmt/global-chart`),
  via `gh` CLI. See `docs/agents/issue-tracker.md`
- **Triage labels** — cinque ruoli canonici, label = nome del ruolo (default).
  See `docs/agents/triage-labels.md`
- **Domain docs** — single-context: `CONTEXT.md` + `docs/adr/` alla root. See
  `docs/agents/domain.md`
