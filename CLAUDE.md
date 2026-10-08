# CLAUDE.md

Global-chart is a reusable Helm chart providing multi-deployment Kubernetes
building blocks. `README.md` — feature list and examples. `CHANGELOG.md` —
version history and migration guides. `docs/adr/` — the decisions behind the
rules below.

## Commands

```bash
make all                    # check + generate + kubeconform + kube-linter
make check                  # the fast loop: lint-chart, lint-templates, unit-test, bad-values, null-sweep
make lint-chart             # lint every scenario in TEST_CASES
make lint-templates         # the mechanical rules of CODING_STANDARDS.md
make unit-test              # helm-unittest suites via Docker
make null-sweep             # null every values node of every scenario: each must render or fail naming its path
make generate-docs          # regenerate the helm-docs README
make e2e                    # install/upgrade/rollback/uninstall on a throwaway kind cluster (runs e2e-routes first)
make e2e-routes             # every rendered Gateway API route, server-side dry run against the real CRDs
make e2e-argocd             # the same cluster, synced by Argo CD (hook lifecycle under Argo)
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
- `tests/` — lint scenario values + `bad-values/` for rejection tests, in three
  classes: `schema/` (rejected by `values.schema.json`), `fail/` (rejected by a
  template `fail`) and `skip-schema/` (rejected by the schema, *and* by a
  template `fail` under `--skip-schema-validation`: a guard the schema shadows,
  the only protection left on the escape hatch ADR 0017 recommends). The
  directory *is* the declaration and `validate-bad-values` asserts it, so a
  schema hole covered by a `fail` cannot pass as coverage. Every `fail/` and
  `skip-schema/` fixture carries one or more `# Expected fail substring: "…"`
  lines, and each must appear in the error: a fixture rejected by the wrong
  `fail` does not pass. helm-unittest cannot skip the schema, so a shadowed
  guard is tested in `skip-schema/`, never in a suite

### Helper Files

**Every helper opens with a header comment carrying its own rules, its
rationale and its ADR link. Read that header before editing the domain** — it
is the source of truth, this table is only the routing.

| File | Domain |
|------|--------|
| `_helpers.tpl` | Naming and labels: `truncName`, `mergeLabels`, and every generated name with its truncation constant |
| `_image-helpers.tpl` | `imageString`, `imagePullPolicy`; mirrored by the image `pattern`s and `$defs/imageMap` in the schema (ADR 0018) |
| `_job-helpers.tpl` | The one pod spec of every hook and cronjob, both scopes: image resolution, CronJob and Job spec fields, `jobValuesPath` |
| `_serviceaccount-helpers.tpl` | Every ServiceAccount rendered or bound (`resolveServiceAccount`, the job resolver) and the SA side of the hook copies (ADR 0010, 0011) |
| `_hook-helpers.tpl` | The `helm.sh/hook*` annotations from the role table, the phase cut `hookReadsPrereqCopy`, the hook-copy consumer scans |
| `_render-helpers.tpl` | `printScalar`, `isSet`, null checks (`rejectNull`, `rejectNullItems`, `isNamedEntry`), render blocks, ports, `resolveBackend`, `podSpecOwners`, route lists |
| `_keda-helpers.tpl` | KEDA names, trigger and `authenticationRef` resolution |
| `_validate-helpers.tpl` | Values paths, the `fail` shape, cross-resource validators, `validateNullItems` / `rejectNullInLists`, `hpaActiveTargets`, `requireCrd` / `requireGatewayApiCrd` |

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
   affinity, priorityClassName. Override with an
   explicit value; use empty `{}`, `[]` or `""` (priorityClassName) to stop inheritance — except the
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
     d'ambiente* in `GLOSSARY.md`
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
    its properties is **closed** (ADR 0006), unless it is a *passthrough surface*
    that stays open under the rule that follows. A *passthrough surface* (a
    Kubernetes or operator shape handed to a manifest verbatim) whose shape is
    small and fixed is closed in full — probes, NetworkPolicy rules,
    `sourceRef`; one that is large or growing (`volumes`, `volumeMounts`,
    `container`) stays open and declares only the fields a template reads — see
    `docs/adr/0017-close-the-passthrough-surfaces-whose-shape-is-small-and-fixed.md`. The
    job composites and `httpRoute` / `httpRouteEntry` close with
    `unevaluatedProperties: false` (Helm >= 3.18.6; below it, ignored in
    silence), the flat ones with `additionalProperties: false`. The `allOf`
    branches (`jobCommon`, `cronJobSpec`, `hookJobSpec`, `rootJobSpec`,
    `deploymentJobSpec`, `httpRouteFields`) must
    **never** be closed: a branch validates the whole object alone, so closing
    one rejects every key the others contribute. **Every closed schema node carries
    its own fixture** in `tests/bad-values/schema/` — a top-level `$defs` and
    every closure nested in one alike — linked by a `# covers: <pointer>` line
    and enforced by `tests/bad-values/check-closure-coverage.py`, which also
    removes each closure in turn and requires its fixture to pass without it.
    The script's docstring is the single home of the pointer syntax and the
    rules; read it before adding a closure. A closed `oneOf` branch goes in a
    `$defs` of its own (`imageMap`). Name the file after the scope and kind
    the values use (`root-cronjob-`, `deployment-hook-`), not after the schema
    path — the `# covers:` line is what ties the two together.
    A map key that becomes part of a name (`deployments`, `cronJobs`, `hooks`
    and its types, `externalSecrets`, `kedaTriggerAuthentications`, both
    scopes) is constrained by `propertyNames` to what the tightest place it
    lands in accepts — a new such map needs one too, with its own fixture. A
    list field that identifies its entry and becomes a name is held to the same
    rule, by a `$ref` on the field: `rbacs.roles[].name` (ADR 0008). See
    *Chiave nominante* in `GLOSSARY.md`
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
14. **One HTTP routing layer, any number of L4 routes**: `ingress` and the
    HTTPRoutes (`httpRoute`, `httpRoutes`, listed by `httpRouteEntries`)
    exclude each other; `tcpRoutes` / `udpRoutes` coexist with either. The
    rules (protocol per consumer, `v1` only from Gateway API v1.6.0) live in
    the headers of `l4routes.yaml` and `resolveBackend`. As with KEDA, every
    route kind is guarded by its CRD (`requireGatewayApiCrd`), so an offline
    render needs `--api-versions gateway.networking.k8s.io/v1/<Kind>` for
    HTTPRoute, TCPRoute and UDPRoute (`HELM_API_VERSIONS`;
    `capabilities.apiVersions` in the suites)
15. **The chart renders only what it can validate**: a workload enters when its
    pod spec goes through the same helpers and validation as the Deployment's.
    No free-form manifest field (`extraObjects`, `rawResources`), and
    `--skip-schema-validation` is never in an application's CI — the values are
    written by people and LLMs who learn the chart only from what it rejects.
    See `docs/adr/0019-the-chart-renders-only-what-it-can-validate.md`

### Resource Naming Limits

Kubernetes caps a name at 63 characters, so most resources truncate there. Three
exceptions, each owned by a name helper in `_helpers.tpl`:

| Resource | Limit |
|----------|-------|
| CronJobs | 52 — Kubernetes appends an 11-char timestamp to the Job it creates |
| `mountedConfigFiles` `name` | 52, DNS-1123 label, enforced by `values.schema.json` — it feeds the pod volume name, and a volume name is a DNS-1123 *label* |
| Mounted config file ConfigMap | Not truncated at all: a ConfigMap name is a DNS *subdomain*, so it has room the volume does not. Truncating would manufacture the collision `validateNameCollisions` exists to catch |

## Coding standards

`CODING_STANDARDS.md` — how templates and helpers are written: `default` on
booleans, `printScalar` for numbers, `hasKey` for inheritance, the
`<values path>: <problem>` shape of a `fail`, one home per enumeration. Read it
before writing a template or helper. The mechanical rules are checked by
`make lint-templates` and `make null-sweep`; `make check` runs the fast loop.

## Agent skills

`GLOSSARY.md`, `docs/agents/` and `docs/adr/` are tracked. They stay out of the
chart package, which contains only `charts/global-chart/`.

### Issue tracker

GitHub Issues on `filippolmt/global-chart`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: `GLOSSARY.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
