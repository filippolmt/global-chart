# CLAUDE.md

Global-chart is a reusable Helm chart providing multi-deployment Kubernetes
building blocks. `README.md` — feature list and examples. `CHANGELOG.md` —
version history and migration guides. `docs/adr/` — the decisions behind the
rules below.

## Commands

```bash
make all                    # check + generate + kubeconform + kube-linter
make check                  # the fast loop: lint-chart, lint-templates, lint-docs, unit-test, bad-values, null-sweep
make lint-chart             # lint every scenario in TEST_CASES
make lint-templates         # the mechanical rules of CODING_STANDARDS.md
make lint-docs              # every file a document or a comment points at exists
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

Offline renders: `.Capabilities.APIVersions` carries CRDs only during a real
install, so `helm template` of a KEDA or Gateway API scenario needs the
`--api-versions` in `HELM_API_VERSIONS` (`capabilities.apiVersions` in the
suites). `helm lint` evaluates no template `fail`: it logs it at INFO and
passes, so a `fail` is proven by `tests/bad-values/` and the suites.

## Architecture

### File Layout

- `charts/global-chart/templates/` — Helm templates; `_*.tpl` are the
  domain-split helpers below
- `charts/global-chart/values.schema.json` — JSON Schema
- `charts/global-chart/tests/` — helm-unittest suites, one `*_test.yaml` per
  template
- `tests/` — lint scenario values + `bad-values/` for rejection tests. Before
  adding a fixture, read *Schema validation* in the README's *Testing & CI*:
  the subdirectory declares which mechanism must reject it

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

### Invariants

Each line is the rule; the pointer is where its reasons and edge cases live.
Read the pointer before changing the domain it names.

1. **Deployments**: each `deployments.<name>` renders its own Deployment,
   Service, ServiceAccount, ConfigMap, Secret, HPA, PDB and NetworkPolicy,
   named `{release}-{chart}-{name}`. The selector label
   `app.kubernetes.io/component: {name}` keeps their pods apart, and a
   selector is immutable: README, *Decide before the first install*.
2. **Job scopes**: deployment-scope hooks and cronjobs inherit from their
   deployment, root-scope ones inherit nothing (*Root scope / deployment
   scope* in `GLOSSARY.md`). `command` / `args` and `mountedConfigFiles` stay
   with the Deployment, and the `envFrom` lists add up. What is inherited, the
   opt-out toggles and the `envFrom` order: the *Inheritance* block of the
   `jobPodSpec` header in `_job-helpers.tpl`.
3. **Fallback chains**: job > deployment > global, `hasKey` at every level; an
   explicit `[]` stops the fallback. `CODING_STANDARDS.md`.
4. **Hooks**: weights and delete policies come only from the role table in
   `_hook-helpers.tpl`, which keeps `prereq < SA < Job` and lets weights go
   negative. A hook reads *hook prerequisite copies* under their own names.
   Before touching `hook.yaml`, a weight, a delete policy or a copy, read the
   headers of `_hook-helpers.tpl` and `_serviceaccount-helpers.tpl`, then the
   ADR of the copy: 0011 (ServiceAccount), 0007 (ExternalSecret), 0010 (RBAC),
   0015 (cleanup on failure).
5. **Schema closure**: a `$defs` that declares its properties is closed
   (ADR 0006); a *passthrough surface* is closed when its shape is small and
   fixed, and otherwise declares only the fields a template reads (ADR 0017);
   the six `allOf` branches stay open. Every closure carries a fixture: read
   the docstring of `tests/bad-values/check-closure-coverage.py` before adding
   one. A *naming key* is constrained by `propertyNames`, or by a `$ref` on a
   list field (ADR 0008). `mountedConfigFiles` items carry no `required`: the
   templates check them, so `failedTemplate` tests stay possible.
6. **One replica owner**: `autoscaling` (HPA) and `keda` (ScaledObject)
   exclude each other per deployment, and either one omits `spec.replicas`
   (*Replica owner* in `GLOSSARY.md`, ADR 0003, ADR 0012).
7. **No `appVersion`**: `app.kubernetes.io/version` is emitted only when the
   consumer sets it through `global.commonLabels`; selectors never carry it.
8. **Ports**: the *primary port* has one source per side, `servicePrimaryPort`
   for the Service and `containerPorts` for the pod, and every consumer reads
   those helpers. Rules and the bugs behind them (issue #82): the headers in
   `_render-helpers.tpl`.
9. **Routing**: one *HTTP routing layer* (Ingress or HTTPRoutes), any number
   of *L4 routes*. Rules: the headers of `l4routes.yaml` and `resolveBackend`.
10. **Scope**: the chart renders only what it can validate, with no free-form
    manifest field. ADR 0019.

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
