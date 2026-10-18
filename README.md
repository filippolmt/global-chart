# Global Helm Chart

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/global-chart)](https://artifacthub.io/packages/search?repo=global-chart)

Reusable Helm chart providing configurable building blocks—Deployments, StatefulSets, Services, Ingress, Jobs, ExternalSecrets, and more—for broadly adaptable Kubernetes applications.
The chart supports **multiple workloads** in a single release, each with independent configuration. CronJobs and Hooks can be defined at root level or inside workloads to inherit their configuration.

## Chart scope at a glance

- **Multi-deployment support**
  Define multiple independent workloads under `workloads.*`. Each gets its own Service, ConfigMap, Secret, ServiceAccount, HPA, PDB, and NetworkPolicy.
- **StatefulSets**
  `kind: StatefulSet` on a `workloads` entry renders a StatefulSet instead of a Deployment, with one claim per pod from `volumeClaimTemplates` and a headless governing Service (see [Stateful workloads](#stateful-workloads-kind-statefulset)). Everything else about the entry stays the same.
- **Workload primitives**
  Image can be a string (`nginx:1.25`) or a map (`repository/tag/digest`), held by the schema to the reference grammar the kubelet parses; `tag` is a string, so quote a numeric-looking one (`"1.20"`). Probes, resources, autoscaling (HPA), scheduling constraints, extra containers/init containers, pod recreation bumps, and ConfigMap/Secret `envFrom` are all configurable. `command`/`args` override the image entrypoint per workload, so one image can back several workloads (web, worker, …); they are never inherited by the deployment's hooks/cronJobs.
- **Networking**
  First-class Service configuration (with per-service annotations) plus optional Ingress with TLS, class annotations, and routes to specific workloads. DNS options and host aliases can be defined per workload.
  HTTP reaches the workloads through one routing layer, Ingress or Gateway API HTTPRoutes (`httpRoute` for one, `httpRoutes` for one per entry), never both. Ports that are not HTTP go through TCPRoutes and UDPRoutes (`tcpRoutes`, `udpRoutes`), alongside either (see [Exposing a TCP or UDP port](#exposing-a-tcp-or-udp-port-through-a-gateway)). A `workload:` backend picks a port of its Service by name with `portName`.
- **Configuration distribution**
  Inline ConfigMap/Secret data, mounted config files (single file) or bundles (projected lists of files), and `volumes` in the native Kubernetes form (any volume source) are supported.
- **Lifecycle and batch**
  Helm hook jobs and CronJobs can be defined in two ways:
  - **Root level** (`hooks.*`, `cronJobs.*`): Standalone, use `fromWorkload` to copy image and its `pullPolicy` from a workload
  - **Inside workloads** (`workloads.*.hooks`, `workloads.*.cronJobs`): Inherit image, configMap, secret, serviceAccount, hostAliases, podSecurityContext, securityContext, dnsConfig (cronJobs), nodeSelector, tolerations, affinity, priorityClassName, and more from the parent workload
  - `priorityClassName` is inherited too: a cronjob of a workload with a preempting PriorityClass can evict other pods on every run. Set `priorityClassName: ""` on the job (or a lower class) to stop it
  - A workload-scope job's `envFrom` adds its own `envFromConfigMaps` / `envFromSecrets` after the workload's, never replacing them. To drop what it inherits, set `false` on `inheritWorkloadConfigMap` / `inheritWorkloadSecret` (the generated ConfigMap/Secret) or `inheritWorkloadEnvFromConfigMaps` / `inheritWorkloadEnvFromSecrets` (the workload's lists)
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
- **Out of scope**
  The chart renders Deployments, StatefulSets, CronJobs and hook Jobs, and only what its schema and templates can validate. There is no free-form manifest field (`extraObjects`, `rawResources`): an object the chart cannot validate belongs in another chart or in the application's own manifests. Keep `--skip-schema-validation` out of CI; it is a one-off way out for a Kubernetes field the chart does not list yet. See [ADR 0019](docs/adr/0019-the-chart-renders-only-what-it-can-validate.md).

## Prerequisites

- Helm >= 3.18.6 (Helm 4 supported). Below it, the schema closures of the four job
  composites (`cronJobs` and `hooks`, both scopes) and of `httpRoute` / `httpRoutes`
  are ignored without a word, so a typo there renders instead of being rejected. `helm install`/`upgrade` warn about it
- Kubernetes 1.27 or newer — the floor is a StatefulSet's `persistentVolumeClaimRetentionPolicy`, on by default from 1.27: below it the API server drops the field without a word, and with it the claims' `Retain`
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

A workload's `spec.selector` is immutable in Kubernetes, for a Deployment and a StatefulSet alike. This chart builds it
from three labels, and two of them are worth a decision *before* the release
exists, because changing them later fails the upgrade:

| Selector label | Value | Changed by |
|----------------|-------|------------|
| `app.kubernetes.io/name` | the **chart** name, `global-chart` | `nameOverride` |
| `app.kubernetes.io/instance` | the release name | `helm upgrade --install <name>` |
| `app.kubernetes.io/component` | the key under `workloads` | renaming that key |

`app.kubernetes.io/name` defaults to the chart name rather than to your
application's name — that is what a generic chart knows about itself. The
application's identity lives in `helm.sh/chart`, the release name, and the
workload key. If you want the conventional per-application value, set
`nameOverride` at the first install:

```yaml
nameOverride: dify   # app.kubernetes.io/name: dify, instead of global-chart
```

Setting or changing it on a release that already exists produces:

```
Deployment.apps "dify-api" is invalid: spec.selector: ... field is immutable
```

The only way through is to delete the workload and let Helm recreate it
(safe for stateless workloads, a real outage window for everything else). The
same applies to renaming a key under `workloads`: `web` → `frontend` orphans
the old workload and creates a new one.

Adopting a workload that another chart already manages hits the same wall
whenever the two selectors differ — no chart can adopt an arbitrary selector.

Changing `kind` on an installed entry (`Deployment` ↔ `StatefulSet`) is not an
edit either: the old workload is deleted and the new one created, and for a
moment the pods of both match the same selector and the same Service. A
StatefulSet adds its own immutable fields: `volumeClaimTemplates`,
`podManagementPolicy` and `serviceName` (see
[Stateful workloads](#stateful-workloads-kind-statefulset)).

## Stateful workloads: `kind: StatefulSet`

A database, a search engine or a message broker keeps state per pod. A
`workloads` entry with `kind: StatefulSet` renders a StatefulSet: each pod has
a stable name (`<fullname>-<key>-0`, `-1`, …) and, for each
`volumeClaimTemplates` entry, a claim of its own that follows it across
restarts. The rest of the entry (image, config, Service, HPA/KEDA, PDB,
NetworkPolicy, hooks and cronJobs) works as on a Deployment. See
[ADR 0020](docs/adr/0020-a-workload-kind-on-the-deployments-entry.md).

```yaml
workloads:
  search:
    kind: StatefulSet
    image: docker.elastic.co/elasticsearch/elasticsearch:8.15.0
    replicaCount: 1
    service:
      port: 9200
      targetPort: 9200
    volumeMounts:
      - name: data
        mountPath: /usr/share/elasticsearch/data
    volumeClaimTemplates:
      - name: data                    # claim data-<fullname>-search-0
        size: 10Gi
        storageClassName: standard-rwo
```

- **Headless Service.** Every StatefulSet gets `<fullname>-<key>-headless`
  (`clusterIP: None`, `publishNotReadyAddresses: true`), even with
  `service.enabled: false`: the pods resolve as
  `<pod>.<fullname>-<key>-headless`, for peer discovery. Routes and the
  Ingress keep pointing to the normal Service. It carries the `service` ports,
  which only name its SRV records: with `service.enabled: false` they are the
  primary port's defaults (80, `http`) unless `service` declares others, and
  it takes the common annotations only, never `service.annotations`, which
  target the normal Service (external-dns, a cloud load balancer).
- **The claims outlive the release.** `persistentVolumeClaimRetentionPolicy`
  defaults to `Retain` on deletion and on scale-down, and the claims are not
  in the manifest: neither `helm uninstall` nor an Argo CD prune deletes them.
  Delete them by hand when the data is no longer wanted.
- **One claim per pod, not one per StatefulSet.** Pods do not share a claim.
  A volume shared between pods needs `ReadWriteMany` (Filestore, EFS, Azure
  Files: rarely a cluster's default class): create the claim outside the chart
  and mount it with `volumes[].persistentVolumeClaim.claimName`.
- **A cloud block disk lives in one zone.** The pod stays in the zone where its
  claim was created. Use a StorageClass with
  `volumeBindingMode: WaitForFirstConsumer`, or the disk can be created in a
  zone where the pod cannot be scheduled.
- **`volumeClaimTemplates` is immutable.** Changing a size, a storage class or
  a label fails the upgrade. The way through keeps the pods and their claims:

  ```bash
  kubectl delete sts <fullname>-<key> --cascade=orphan
  helm upgrade ...   # or sync: the StatefulSet is recreated and adopts the pods
  ```

  The existing claims keep their old spec; growing one means editing the claim
  itself, when its StorageClass allows volume expansion. For the same reason
  the claims carry only the selector labels and their own `labels` and
  `annotations`, never `helm.sh/chart` or `global.commonLabels`.
- **Name.** A StatefulSet's `<fullname>-<key>` is at most 52 characters: each
  pod carries `controller-revision-hash: <name>-<hash>`, and a label value
  holds 63. A longer name fails the render.
- **Fields of one kind only.** `strategy` and `progressDeadlineSeconds` belong
  to a Deployment; `updateStrategy`, `podManagementPolicy`,
  `volumeClaimTemplates` and `persistentVolumeClaimRetentionPolicy` to a
  StatefulSet. The schema rejects them on the other kind.

## Example: Multi-deployment with inherited hooks/cronJobs

```yaml
workloads:
  backend:
    image: myapp/backend:v2.0
    replicaCount: 2
    configMap:
      DB_HOST: postgres.db.svc
    secret:
      DB_PASSWORD: supersecret
    serviceAccount:
      create: true
    # Hooks inside workload - inherit image, configMap, secret, SA.
    # A pre-* or post-delete hook works with a chart-created SA too: the chart
    # emits a hook copy <sa>-hook and the hook runs as it (ADR 0011), since
    # normal resources are created after hooks. An identity keyed on the SA
    # name (Workload Identity, IRSA) does not reach the copy.
    hooks:
      pre-upgrade:
        migrate:
          command: ["./migrate.sh"]
    # CronJobs inside workload - inherit everything from parent
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

# Root-level hooks (standalone, must specify image or fromWorkload)
hooks:
  post-upgrade:
    notify:
      image: curlimages/curl:latest
      command: ["curl", "-X", "POST", "https://hooks.slack.com/..."]

# Ingress routes to specific workloads
ingress:
  enabled: true
  hosts:
    - host: api.example.com
      workload: backend
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

workloads:
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
one. The workload, its cronjobs and every other hook read the real Secret, a
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

## Rolling the pods on an ExternalSecret change

A workload that references `externalSecrets` carries a
`checksum/external-secrets` pod annotation: the sha256 of the rendered specs of
the entries it references, in list order. A change to `target.template`, to
`remote.key`/`property` or to the list rolls its pods, as `checksum/secret` does
for `secret`. It hashes the spec, not the values, so it does **not** cover a new
version of the value in the external store, nor the window in which the new
pods may start before ESO has rewritten the Secret, nor a `target.immutable:
true` Secret, which ESO cannot update in place. `podAnnotations` overrides it
like the other checksums; hooks and cronjobs get none, since their pods are
created on every run.

The first two need a controller that watches the Secret itself. With
[Stakater Reloader](https://github.com/stakater/Reloader) installed, opt in per
workload:

```yaml
workloads:
  app:
    image: myapp:v1
    externalSecrets:
      - name: app-env
    reloader:
      externalSecrets: true
```

The workload's metadata gets `secret.reloader.stakater.com/reload` with the
target of every referenced entry, env and mounted alike, read from the same
resolver as the pod wiring — never hardcode a generated name. A reload list you
set yourself, in `annotations`, `global.commonAnnotations` or both, is merged
with it entry by entry, duplicates removed. The field fails the render when the workload references
no `externalSecrets`, and does nothing without Reloader. Hooks and cronjobs are
not covered (ADR 0016).

- After a spec change the pods roll twice, on purpose: the checksum rolls them,
  then Reloader rolls them again once ESO has rewritten the Secret. The second
  rollout closes the race.
- Under Argo CD or Flux, run Reloader with `--reload-strategy=annotations`: the
  default `env-vars` strategy edits the pod template, which the GitOps
  controller then reports as drift and reverts.
- A `target.immutable` or `refreshPolicy: CreatedOnce` target stays in the list,
  but ESO never rewrites it, so Reloader never fires for it.

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

workloads:
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

## Several HTTPRoutes in one release

A rule of an HTTPRoute cannot match on hostname, so two hostnames that must
reach different workloads, or attach to different Gateways, need two routes.
`httpRoutes` is a map: one HTTPRoute per entry, named `<fullname>-<key>`, with
the fields of `httpRoute` minus `enabled` (an entry present is a route
rendered). `httpRoute` stays the shorthand for one route and coexists with the
map; together they are the HTTP routing layer, so neither goes with `ingress`.

```yaml
httpRoute:
  enabled: true
  parentRefs: [{ name: shared-gateway, namespace: envoy-gateway-system }]
  hostnames: [app.example.com]
  rules:
    - backendRefs: [{ workload: nginx }]

httpRoutes:
  traccar-web:
    parentRefs: [{ name: shared-gateway, namespace: envoy-gateway-system }]
    hostnames: [traccar.example.com]
    rules:
      - backendRefs: [{ workload: traccar }]
```

## Exposing a TCP or UDP port through a Gateway

`tcpRoutes` and `udpRoutes` are maps: one TCPRoute (or UDPRoute) per entry,
named `<fullname>-<key>`, so a release can attach to several Gateways and
listeners. An entry present is a route rendered. They coexist with `ingress`
and `httpRoute`; as with `httpRoute`, the chart does not create Gateways or
listeners. Here the web UI of Traccar goes through `httpRoute` on a proxied
Gateway, and the GPS trackers' binary protocol through a TCPRoute on another:

```yaml
workloads:
  traccar:
    service:
      port: 8082          # web UI and API
      portName: http
      extraPorts:
        - name: teltonika
          port: 5027
          targetPort: 5027

httpRoute:
  enabled: true
  parentRefs: [{ name: shared-gateway, namespace: envoy-gateway-system }]
  hostnames: [traccar.example.com]
  rules:
    - backendRefs: [{ workload: traccar }]

tcpRoutes:
  gps:
    parentRefs:
      - name: direct-gateway
        namespace: envoy-gateway-system
        sectionName: gps-5027   # one TCP listener per port on the Gateway
    rules:
      - backendRefs:
          - workload: traccar
            portName: teltonika
```

`portName` names a port of the workload's Service, `service.portName` or a
`service.extraPorts[].name`, and works the same in `ingress.hosts[]` and
`httpRoute` backendRefs; omitted, the backend is the primary port. The render
fails on a name the Service lacks, on `portName` next to `service:`, and on a
port whose protocol is not the one the route forwards: TCP for ingress,
`httpRoute` and `tcpRoutes`, UDP for `udpRoutes`. Kubernetes would accept the
route, and the traffic would never arrive.

`httpRoute` is guarded the same way: the render fails unless the cluster serves
`gateway.networking.k8s.io/v1` HTTPRoute (Gateway API v1.0.0 or later), and an
offline render needs `--api-versions gateway.networking.k8s.io/v1/HTTPRoute`.
Argo CD passes the destination cluster's API versions, kinds included, so an
Argo CD Application needs nothing; a pre-render in CI does need the flag.

Only `gateway.networking.k8s.io/v1` is rendered. TCPRoute and UDPRoute reach it
in **Gateway API v1.6.0**, in the standard and experimental channels alike; up to
v1.5 they are `v1alpha2`, experimental only. The render fails unless the cluster
serves `v1` for each kind the release uses. Check with
`kubectl get crd tcproutes.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}'`.
An offline render (`helm template`, a GitOps pre-render) needs
`--api-versions gateway.networking.k8s.io/v1/TCPRoute` and/or
`--api-versions gateway.networking.k8s.io/v1/UDPRoute`.

## Local development

```bash
# Show all available commands
make help

# Run full pipeline: lint, unit tests, bad-values, generate, kubeconform, kube-linter
make all

# Individual targets
make lint-chart            # Lint every scenario in TEST_CASES (see the Makefile)
make lint-docs             # Check that every file a document or a comment points at exists
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
- **Schema validation** (`make validate-bad-values`): Verifies every fixture in `tests/bad-values/` is rejected, and by the right mechanism. The directory is the declaration: a file in `schema/` must be rejected by `values.schema.json` (the target asserts Helm's schema error message), a file in `fail/` by a template `fail` and *not* by the schema, and a file in `skip-schema/` by the schema *and*, under `--skip-schema-validation`, by the template `fail` the schema shadows (a *backstop guard*: the only protection left on that way out). Without the split, a schema hole covered by a `fail` is invisible. Every `fail/` and `skip-schema/` fixture carries one or more `# Expected fail substring: "…"` lines, and each must appear in the error, so a fixture rejected by the wrong `fail` does not pass. helm-unittest cannot skip the schema, so a backstop guard is tested in `skip-schema/`, never in a suite. `tests/bad-values/check-closure-coverage.py` then checks that every closed object in the schema has a fixture of its own, linked by a `# covers: <pointer>` line, and that the fixture stops being rejected once that closure is removed — so closing an object without testing it, or with a fixture that tests something else, fails here.
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
| `multi-workload.yaml`            | Multi-workload test (frontend, backend, worker, minimal)                                  |
| `workload-hooks-cronjobs.yaml`   | Hooks/CronJobs inside workloads (inheritance test)                                        |
| `hooks-sa-inheritance.yaml`      | Hooks SA inheritance (existing SA, explicit override)                                     |
| `mountedcm*.yaml`                | Mounted config file scenarios                                                             |
| `cron-only.yaml`                 | CronJobs without a workload                                                               |
| `hook-only.yaml`                 | Hooks without a workload                                                                  |
| `externalsecret-only.yaml`       | ExternalSecrets only                                                                      |
| `externalsecret-hooks.yaml`      | ExternalSecrets read by hooks (hook-prerequisite copy) and cronjobs                       |
| `ingress-custom.yaml`            | Ingress with workload reference                                                           |
| `external-ingress.yaml`          | Ingress pointing to external service                                                      |
| `httproute-basic.yaml`           | Gateway API HTTPRoute, plain backend                                                      |
| `httproute-canary.yaml`          | HTTPRoute with weighted backends                                                          |
| `httproute-filters.yaml`         | HTTPRoute rule filters                                                                    |
| `httproutes.yaml`                | `httpRoutes` entries next to `httpRoute`, a redirect-only route                           |
| `l4routes.yaml`                  | TCPRoute and UDPRoute to named extra ports, alongside an HTTPRoute                        |
| `keda.yaml`                      | KEDA ScaledObject and TriggerAuthentication                                               |
| `rbac.yaml`                      | RBAC with roles and service accounts                                                      |
| `rbac-hooks.yaml`                | RBAC roles read by hooks (hook-prerequisite copy, ADR 0010)                               |
| `service-disabled.yaml`          | Deployment with service disabled                                                          |
| `service-extra-ports.yaml`       | Service with extraPorts, and the container ports derived from them                        |
| `common-annotations.yaml`        | `global.commonAnnotations` colliding with per-resource ones — catches a duplicate YAML key                |
| `statefulset.yaml`               | StatefulSets with claim templates, headless Service, HPA and KEDA targets, a sidecar-mounted claim |
| `raw-workload.yaml`              | Workload with raw image string                                                            |
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
- Domain terms: [`GLOSSARY.md`](GLOSSARY.md)
- Design decisions: [`docs/adr/`](docs/adr/)
- Contributing: [`CODING_STANDARDS.md`](CODING_STANDARDS.md) for templates and helpers, [`CLAUDE.md`](CLAUDE.md) for the commands and invariants
