# Global Helm Chart

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/global-chart)](https://artifacthub.io/packages/search?repo=global-chart)

Reusable Helm chart providing configurable building blocks—Deployments, Services, Ingress, Jobs, ExternalSecrets, and more—for broadly adaptable Kubernetes applications.
The chart supports **multiple deployments** in a single release, each with independent configuration. CronJobs and Hooks can be defined at root level or inside deployments to inherit their configuration.

## Chart scope at a glance

- **Multi-deployment support**
  Define multiple independent deployments under `deployments.*`. Each gets its own Service, ConfigMap, Secret, ServiceAccount, HPA, PDB, and NetworkPolicy.
- **Deployment primitives**
  Image can be a string (`nginx:1.25`) or a map (`repository/tag/digest`), held by the schema to the reference grammar the kubelet parses; `tag` is a string, so quote a numeric-looking one (`"1.20"`). Probes, resources, autoscaling (HPA), scheduling constraints, extra containers/init containers, pod recreation bumps, and ConfigMap/Secret `envFrom` are all configurable. `command`/`args` override the image entrypoint per deployment, so one image can back several workloads (web, worker, …); they are never inherited by the deployment's hooks/cronJobs.
- **Networking**
  First-class Service configuration (with per-service annotations) plus optional Ingress with TLS, class annotations, and routes to specific deployments. DNS options and host aliases can be defined per-deployment.
- **Configuration distribution**
  Inline ConfigMap/Secret data, mounted config files (single file) or bundles (projected lists of files), and volume templates (configMap/secret/emptyDir/PVC or native K8s spec) are supported.
- **Lifecycle and batch**
  Helm hook jobs and CronJobs can be defined in two ways:
  - **Root level** (`hooks.*`, `cronJobs.*`): Standalone, use `fromDeployment` to copy image and its `pullPolicy` from a deployment
  - **Inside deployments** (`deployments.*.hooks`, `deployments.*.cronJobs`): Inherit image, configMap, secret, serviceAccount, hostAliases, podSecurityContext, securityContext, dnsConfig (cronJobs), nodeSelector, tolerations, affinity, priorityClassName, and more from the parent deployment
  - `priorityClassName` is inherited too: a cronjob of a deployment with a preempting PriorityClass can evict other pods on every run. Set `priorityClassName: ""` on the job (or a lower class) to stop it
  - A deployment-level job's `envFrom` adds its own `envFromConfigMaps` / `envFromSecrets` after the deployment's, never replacing them. To drop what it inherits, set `false` on `inheritDeploymentConfigMap` / `inheritDeploymentSecret` (the generated ConfigMap/Secret) or `inheritDeploymentEnvFromConfigMaps` / `inheritDeploymentEnvFromSecrets` (the deployment's lists)
  - Hook prerequisite ConfigMap/Secret are created automatically with correct weight ordering
  - A `pre-*` or `post-delete` hook can read a Secret produced by the release's own `externalSecrets`: reference it by key (see [Reading an ExternalSecret from a hook](#reading-an-externalsecret-from-a-hook))
- **Secret management**
  ExternalSecret resources with required field validation to avoid silent misconfigurations. Each entry maps a single remote key (`remote`/`secretkey`), many keys into one Secret via a `data` list, or pulls in bulk via `dataFrom` (`extract`/`find`).
- **RBAC**
  Create Roles, ServiceAccounts, and RoleBindings for fine-grained access control.
- **Global values**
  `global.imageRegistry`, `global.imagePullSecrets`, `global.commonLabels`, `global.commonAnnotations` apply across all resources.
- **Validation**
  JSON Schema Draft 2019-09 (`values.schema.json`) for input validation and IDE autocomplete. Name collision detection at render time, and a null `configMap` / `secret` value fails there, naming its values path.

## Prerequisites

- Helm >= 3.18.6 (Helm 4 supported). Below it, the schema closures of the four job
  composites (`cronJobs` and `hooks`, both scopes) are ignored without a word, so a
  typo there renders instead of being rejected. `helm install`/`upgrade` warn about it
- Kubernetes 1.23 or newer — the floor is `autoscaling/v2` for the HPA and `policy/v1` for the PDB
- Docker (for unit tests, kubeconform, kube-linter, helm-docs)

## Quick start

```bash
# Add the chart repository
helm repo add global-chart https://filippolmt.github.io/global-chart
helm repo update

# Install with your values
helm upgrade --install my-release global-chart/global-chart \
  --namespace my-namespace \
  --create-namespace \
  --values path/to/values.yaml
```

## Decide before the first install: the immutable selector

A Deployment's `spec.selector` is immutable in Kubernetes. This chart builds it
from three labels, and two of them are worth a decision *before* the release
exists, because changing them later fails the upgrade:

| Selector label | Value | Changed by |
|----------------|-------|------------|
| `app.kubernetes.io/name` | the **chart** name, `global-chart` | `nameOverride` |
| `app.kubernetes.io/instance` | the release name | `helm upgrade --install <name>` |
| `app.kubernetes.io/component` | the key under `deployments` | renaming that key |

`app.kubernetes.io/name` defaults to the chart name rather than to your
application's name — that is what a generic chart knows about itself. The
application's identity lives in `helm.sh/chart`, the release name, and the
deployment key. If you want the conventional per-application value, set
`nameOverride` at the first install:

```yaml
nameOverride: dify   # app.kubernetes.io/name: dify, instead of global-chart
```

Setting or changing it on a release that already exists produces:

```
Deployment.apps "dify-api" is invalid: spec.selector: ... field is immutable
```

The only way through is to delete the Deployment and let Helm recreate it
(safe for stateless workloads, a real outage window for everything else). The
same applies to renaming a key under `deployments`: `web` → `frontend` orphans
the old Deployment and creates a new one.

Adopting a workload that another chart already manages hits the same wall
whenever the two selectors differ — no chart can adopt an arbitrary selector.

## Example: Multi-deployment with inherited hooks/cronJobs

```yaml
deployments:
  backend:
    image: myapp/backend:v2.0
    replicaCount: 2
    configMap:
      DB_HOST: postgres.db.svc
    secret:
      DB_PASSWORD: supersecret
    serviceAccount:
      create: true
    # Hooks inside deployment - inherit image, configMap, secret, SA.
    # A pre-* or post-delete hook works with a chart-created SA too: the chart
    # emits a hook copy <sa>-hook and the hook runs as it (ADR 0011), since
    # normal resources are created after hooks. An identity keyed on the SA
    # name (Workload Identity, IRSA) does not reach the copy.
    hooks:
      pre-upgrade:
        migrate:
          command: ["./migrate.sh"]
    # CronJobs inside deployment - inherit everything from parent
    cronJobs:
      backup:
        schedule: "0 2 * * *"
        command: ["./backup.sh"]

  worker:
    image: myapp/backend:v2.0 # same image as backend, different entrypoint
    command: ["python", "-m", "app.worker"]
    args: ["--concurrency", "5"]
    service:
      enabled: false # Workers don't need a service

# Root-level hooks (standalone, must specify image or fromDeployment)
hooks:
  post-upgrade:
    notify:
      image: curlimages/curl:latest
      command: ["curl", "-X", "POST", "https://hooks.slack.com/..."]

# Ingress routes to specific deployments
ingress:
  enabled: true
  hosts:
    - host: api.example.com
      deployment: backend
      paths:
        - path: /
```

## Reading an ExternalSecret from a hook

An ExternalSecret is a normal resource, so Helm applies it *after* the `pre-*`
hooks: a migration hook that reads the Secret it produces waits for a Secret
nothing has created yet, on the first install and on the upgrade that adds it.
Under Argo CD, which maps `pre-install` and `pre-upgrade` to `PreSync`, the sync
never gets past it. A `post-delete` hook has the same problem from the other
end: it runs after the ExternalSecret and its Secret are gone.

Reference the Secret by its **`externalSecrets` key**, never by the name it
produces:

```yaml
externalSecrets:
  app-env:
    secretstore: { kind: ClusterSecretStore, name: my-store }
    data:
      - { secretkey: PASSWORD, remote: { key: app, property: password } }

deployments:
  app:
    image: myapp:v1
    externalSecrets:
      - name: app-env                 # envFrom source
      # - name: app-conf
      #   mountPath: /etc/app         # or a read-only volume
    hooks:
      pre-upgrade:
        migrate:                      # inherits the list
          command: ["./migrate.sh"]
```

For every key a `pre-*` or `post-delete` hook references, the chart renders a
hook-prerequisite copy of the ExternalSecret — same spec, its own Secret
`<target>-hook`, owned by the copy and gone with it — and the hook reads that
one. The Deployment, its cronjobs and every other hook read the real Secret, a
`pre-delete` hook included: it runs before Helm deletes anything. A deployment's hooks and
cronjobs inherit its list; a job's own `externalSecrets` (`[]` included)
replaces it. Root-level hooks and cronjobs declare their own.

`envFromSecrets: [<release>-global-chart-app-env]` still works, but gets no
copy and does **not** protect the first install.

When the store cannot deliver, the two runtimes differ. **Helm** does not wait
for custom resources, so it starts the Job at once; the pod stays in
`CreateContainerConfigError` (envFrom) or `ContainerCreating` (volume) and never
reaches `Failed`, so `backoffLimit` does not bound it: `--timeout` (default 5m)
and the hook's own `activeDeadlineSeconds` do. **Argo CD** checks the copy's health
before the next wave and fails the sync as soon as it reports `Ready=False` —
a transient provider error during the hook phase fails the sync.

The copies delete themselves when the attempt fails, too (`hook-failed`), so a
`syncPolicy.retry` attempt does not find the previous copy's Secret still in
place. One race remains: with `PrunePropagationPolicy=background` and a retry
faster than the garbage collector, the retry can still fail once with
`secrets "<target>-hook" already exists`. Argo CD's default foreground
propagation does not have it.

See [ADR 0007](docs/adr/0007-hook-prerequisite-externalsecret-copy.md) and
[ADR 0015](docs/adr/0015-hook-prerequisite-copies-delete-themselves-on-failure.md).

## Running a hook as an `rbacs.roles` ServiceAccount

An `rbacs.roles` entry renders a ServiceAccount, a Role and a RoleBinding. All
three are normal resources, so a `pre-*` hook running as that ServiceAccount
starts before any of them exists, and a `post-delete` hook starts after they are
gone. On a first install, or on the first Argo CD sync, the pod never schedules.
With a pre-existing SA, the pod runs without the Role's rules.

Point the hook at the entry's ServiceAccount by name; nothing else changes:

```yaml
rbacs:
  roles:
    - name: scale-hooks
      serviceAccount: { name: scale-hooks }
      rules:
        - apiGroups: ["apps"]
          resources: ["deployments", "deployments/scale"]
          verbs: ["get", "patch"]

deployments:
  app:
    image: myapp:v1
    hooks:
      pre-upgrade:
        scale-down:
          image: bitnami/kubectl:1.30
          serviceAccountName: scale-hooks
          command: ["kubectl", "scale", "deployment/app", "--replicas=0"]
```

For every entry whose ServiceAccount a `pre-*` or `post-delete` hook runs as,
the chart also renders hook copies under their own names: the Role
`scale-hooks-hook` and the RoleBinding `scale-hooks-rolebinding-hook`. The copies
are deleted once the hook phase succeeds. Which ServiceAccount the hook runs as
depends on the entry:

- **The entry creates the SA** (the default). The chart copies the SA as
  `scale-hooks-hook`, and the hook runs as the copy. An identity bound to the SA
  name, such as GCP Workload Identity or AWS IRSA, does not reach the copy.
- **The entry binds an existing SA** (`create: false`). The hook keeps that SA,
  and only the Role and the RoleBinding are copied. Use this form to keep a
  Workload Identity: create the SA outside the release.

Hooks in other phases run as the real ServiceAccount: `post-upgrade`, say, and
`pre-delete`, which runs before Helm deletes anything. A `pre-rollback` hook gets
the copies, as a `pre-upgrade` one does: the revision it rolls back to may be the
one that adds the entry.

See [ADR 0010](docs/adr/0010-hook-prerequisite-rbac-copy.md).

## Local development

```bash
# Show all available commands
make help

# Run full pipeline: lint, unit tests, bad-values, generate, kubeconform, kube-linter
make all

# Individual targets
make lint-chart            # Lint every scenario in TEST_CASES (see the Makefile)
make unit-test             # Run the helm-unittest suites via Docker
make validate-bad-values   # Verify schema rejects invalid values
make generate-templates    # Render manifests for visual inspection
make kubeconform           # Validate manifests against the pinned K8s schema
make kube-linter           # Lint manifests (addAllBuiltIn)
make generate-docs         # Regenerate helm-docs

# End-to-end install test on a throwaway kind cluster (never touches your kubectl context)
make e2e                   # install + upgrade + uninstall, asserts the hook lifecycle
make kind-delete           # tear the cluster down

# Install a test scenario to a cluster
make install SCENARIO=test01

# Render a single template for debugging
make render VALUES=tests/test01/values.01.yaml TEMPLATE=deployment.yaml
```

## Testing & CI

The chart has multiple layers of testing:

- **Lint scenarios** (`make lint-chart`): Runs `helm lint --strict` across every scenario in `tests/` (the `TEST_CASES` list in the `Makefile`).
- **Unit tests** (`make unit-test`): helm-unittest suites in `charts/global-chart/tests/` (one `*_test.yaml` per template), including negative `failedTemplate` tests.
- **Schema validation** (`make validate-bad-values`): Verifies every fixture in `tests/bad-values/` is rejected, and by the right mechanism. The directory is the declaration: a file in `schema/` must be rejected by `values.schema.json` (the target asserts Helm's schema error message), a file in `fail/` by a template `fail` and *not* by the schema. Without the split, a schema hole covered by a `fail` is invisible. `tests/bad-values/check-closure-coverage.py` then checks that every closed `$defs` in the schema has a fixture of its own, so closing one without testing it fails here.
- **Manifest validation** (`make kubeconform`): Validates the generated resources against the Kubernetes schema pinned in the `Makefile`.
- **Best practices** (`make kube-linter`): Lints manifests with `addAllBuiltIn: true` and the documented exclusions.
- **End-to-end** (`make e2e`): Installs `tests/e2e/values.yaml` on a throwaway kind cluster, then upgrades and uninstalls it. This is the only layer that exercises the *runtime* half of the chart — hook ordering, hook weights and `hook-delete-policy` cleanup — which helm-unittest cannot see because it only renders YAML. It uses its own kubeconfig under `.bin/`, so it can never reach a real cluster. `make e2e-argocd` syncs the chart through Argo CD on the same cluster, where hooks follow Argo CD's lifecycle rather than Helm's.

The GitHub Action (`.github/workflows/helm-ci.yml`) executes all steps on pushes and pull requests, pre-pulling Docker images with retry for resilience.

## Test scenarios

The `tests/` directory is the list — `TEST_CASES` in the `Makefile` is what
`make lint-chart` actually walks. This table is here for the intent of each one:

| File                             | Description                                                                               |
| -------------------------------- | ----------------------------------------------------------------------------------------- |
| `test01/values.01.yaml`          | Full kitchen-sink (autoscaling, volumes, secrets, hooks, crons, ingress, ExternalSecrets) |
| `values.02.yaml`                 | Deployment with existing service account                                                  |
| `values.03.yaml`                 | Chart disabled (no output)                                                                |
| `multi-deployment.yaml`          | Multi-deployment test (frontend, backend, worker, minimal)                                |
| `deployment-hooks-cronjobs.yaml` | Hooks/CronJobs inside deployments (inheritance test)                                      |
| `hooks-sa-inheritance.yaml`      | Hooks SA inheritance (existing SA, explicit override)                                     |
| `mountedcm*.yaml`                | Mounted config file scenarios                                                             |
| `cron-only.yaml`                 | CronJobs without Deployment                                                               |
| `hook-only.yaml`                 | Hooks without Deployment                                                                  |
| `externalsecret-only.yaml`       | ExternalSecrets only                                                                      |
| `externalsecret-hooks.yaml`      | ExternalSecrets read by hooks (hook-prerequisite copy) and cronjobs                       |
| `ingress-custom.yaml`            | Ingress with deployment reference                                                         |
| `external-ingress.yaml`          | Ingress pointing to external service                                                      |
| `httproute-basic.yaml`           | Gateway API HTTPRoute, plain backend                                                      |
| `httproute-canary.yaml`          | HTTPRoute with weighted backends                                                          |
| `httproute-filters.yaml`         | HTTPRoute rule filters                                                                    |
| `keda.yaml`                      | KEDA ScaledObject and TriggerAuthentication                                               |
| `rbac.yaml`                      | RBAC with roles and service accounts                                                      |
| `rbac-hooks.yaml`                | RBAC roles read by hooks (hook-prerequisite copy, ADR 0010)                               |
| `service-disabled.yaml`          | Deployment with service disabled                                                          |
| `service-extra-ports.yaml`       | Service with extraPorts, and the container ports derived from them                        |
| `common-annotations.yaml`        | `global.commonAnnotations` colliding with per-resource ones — catches a duplicate YAML key                |
| `raw-deployment.yaml`            | Deployment with raw image string                                                          |
| `name-collision.yaml`            | Name collision detection test                                                             |
| `bad-values/schema/*.yaml`       | Values the schema must reject                                                             |
| `bad-values/fail/*.yaml`         | Values a template `fail` must reject                                                      |
| `e2e/values.yaml`                | End-to-end install scenario for `make e2e` — see `tests/e2e/README.md`                    |

## Values reference

All configuration lives under `charts/global-chart/values.yaml`. See `charts/global-chart/README.md` for the auto-generated values table.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history, breaking changes, and migration guides. Upgrading from 2.x: follow *Migration guide from 2.x* in the 3.0.0 entry.

## Useful references

- Core values: `charts/global-chart/values.yaml`
- JSON Schema: `charts/global-chart/values.schema.json`
- Example scenarios: `tests/`
- Make targets: `Makefile`
- GitHub workflow: `.github/workflows/helm-ci.yml`
