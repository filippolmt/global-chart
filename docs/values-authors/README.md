# Writing values for global-chart

For the *values author* (`GLOSSARY.md`) and the LLM that helps them: the
rules that are easy to get wrong, and one complete example per common task.
This file is versioned with the chart: read it at the tag of the chart version
your application pins (`global-chart-<version>`).

## What the chart is for

One release runs one application: any number of `workloads.<name>` entries
(each a Deployment, or a StatefulSet with `kind: StatefulSet`), each with its
own Service, ServiceAccount, ConfigMap, Secret, HPA, PDB and NetworkPolicy,
named `<fullname>-<name>` (`<release>-global-chart` unless the release name
already contains `global-chart`, or `nameOverride` / `fullnameOverride` say
otherwise). Around them: CronJobs and Helm hook
Jobs, ExternalSecrets, an Ingress or Gateway API routes, RBAC, KEDA.

Every field is in `charts/global-chart/values.schema.json`, with its
`description`. The chart's own objects are closed: a key the schema does not
declare is rejected. The blocks whose shape belongs to Kubernetes (`affinity`,
`securityContext`, probes, `resources`…) are handed on as written: the API
server, not the chart, checks them.

## Examples

Each one is a complete values file that `make lint-chart` renders in CI.

| Task | File |
|------|------|
| Web application behind an Ingress, with an HPA and a PDB | [`examples/web.yaml`](examples/web.yaml) |
| Queue worker: same image, another command, no Service | [`examples/worker.yaml`](examples/worker.yaml) |
| Scheduled job, in a workload and at the root | [`examples/cronjob.yaml`](examples/cronjob.yaml) |
| Database migration before the new pods | [`examples/migration-hook.yaml`](examples/migration-hook.yaml) |
| Secret from an external store, read by a workload and its hook | [`examples/externalsecret.yaml`](examples/externalsecret.yaml) |

## Rules that are easy to get wrong

**The selector is immutable.** A workload's selector is built from
`app.kubernetes.io/name` (the chart name, or `nameOverride`),
`app.kubernetes.io/instance` (the release name) and
`app.kubernetes.io/component` (the key under `workloads`). Decide them
before the first install. Renaming a `workloads` key renames the workload
too: the old one is deleted, a new one created. `nameOverride` set later
renames it the same way, unless `fullnameOverride` keeps the name: then only
the label changes, and the upgrade fails with `field is immutable`. Changing
`kind` (Deployment ↔ StatefulSet) replaces the workload as well.

**Where a job lives decides what it inherits.** A hook or cronjob declared
under `workloads.<name>.hooks` / `.cronJobs` (*workload scope*) inherits from
that workload: image, `configMap`, `secret`, ServiceAccount,
`envFromConfigMaps` / `envFromSecrets`, `externalSecrets`,
`additionalEnvs`, `imagePullSecrets`, `hostAliases`,
`podSecurityContext`, `securityContext`, `nodeSelector`, `tolerations`,
`affinity`, `priorityClassName`, and `dnsConfig` for a cronjob only. An
explicit value overrides; an empty `{}` or `[]` stops the inheritance, and so
does `priorityClassName: ""`.
The list fields below are the exceptions.

- Never inherited: `command`, `args`, `mountedConfigFiles`, `resources`,
  probes, `volumes`, `volumeMounts`. A job without `command` runs the image's
  entrypoint. A job without `resources` gets the chart's `defaults.resources`,
  not the workload's. A job mounts its own `volumes`, plus the inherited
  `externalSecrets` entries that carry a `mountPath`.
- `additionalEnvs` cannot be stopped: the job's own `env` is appended to the
  workload's.
- `envFromConfigMaps` / `envFromSecrets` add up: the job's own come after the
  workload's. To drop what it inherits, set `false` on
  `inheritWorkloadConfigMap`, `inheritWorkloadSecret`,
  `inheritWorkloadEnvFromConfigMaps` or `inheritWorkloadEnvFromSecrets`.
  A job's own `externalSecrets` replaces the inherited list instead.
- `priorityClassName` is inherited: a cronjob of a workload with a preempting
  class preempts on every run. `priorityClassName: ""` on the job stops it.
- A job under the root `hooks` / `cronJobs` (*root scope*) inherits nothing.
  It sets `image`, or `fromWorkload: <name>`, which copies only the image and
  its `pullPolicy`. Without a `serviceAccount` or `serviceAccountName`, it gets
  a ServiceAccount of its own.

**A migration is a hook of the workload it migrates**, `pre-install` and
`pre-upgrade` under `workloads.<name>.hooks`, not a root hook: it then runs the
image being rolled out, with the workload's configuration, before the new
pods. Normal resources are created after the `pre-*` hooks, so the chart gives
such a hook copies of what it needs (its workload's ConfigMap and Secret, a
ServiceAccount the release creates, an ExternalSecret it references) under
their own names. An identity bound to the ServiceAccount's name (GCP Workload
Identity, AWS IRSA) does not reach the copy: bind a ServiceAccount created
outside the release instead.

**Reference an ExternalSecret by its `externalSecrets` key**, in the
workload's or the job's `externalSecrets` list, never by the Secret name it
produces in `envFromSecrets`. Only a reference by key gives a `pre-*` hook a
copy that exists before the hook runs; by name, the hook waits for a Secret
nothing has created yet on the first install.

**`envFrom` order: the last source wins on a shared key.** A workload lists
`configMap`, `envFromConfigMaps`, `secret`, `envFromSecrets`, then
`externalSecrets`: a Secret always beats a ConfigMap. A workload-scope job
lists what it inherits (the workload's `configMap`, `secret`,
`envFromConfigMaps`, `envFromSecrets`, `externalSecrets`), then its own
(`envFromConfigMaps`, `envFromSecrets`, `externalSecrets`): its own beat the
workload's. A variable in `env` / `additionalEnvs` beats every `envFrom`
source. See *Environment source* in `GLOSSARY.md`.

**One replica owner.** `autoscaling.enabled` (HPA) or `keda.enabled`, never
both. Either one owns the count, and the workload renders no `spec.replicas`.
Without an autoscaler, `replicaCount` defaults to 2.

**No free-form manifest field.** There is no `extraObjects`, `rawResources`
or similar, and none will be added ([ADR 0019](../adr/0019-the-chart-renders-only-what-it-can-validate.md)).
An object the chart cannot render belongs in another chart or in the
application's own manifests. Do not move a rejected block somewhere else that
accepts it, and keep `--skip-schema-validation` out of the application's CI.

**Offline renders of a CRD.** KEDA and Gateway API routes are checked against
the cluster's API versions: `helm template` needs `--api-versions
keda.sh/v1alpha1`, `--api-versions gateway.networking.k8s.io/v1/HTTPRoute`
(or `TCPRoute`, `UDPRoute`). The fail message names the flag. ExternalSecrets
need none.

## Reading a failure

A render the chart refuses fails in one of two ways.

The schema, for a key or a type it does not accept. The path is a JSON
pointer:

```
Error: values don't meet the specifications of the schema(s) in the following chart(s):
global-chart:
- at '/workloads/web': additional properties 'replicas' not allowed
```

A template `fail`, for a rule between values. The message leads with the
values path of the key holding the wrong value, then the problem:
`<values path>: <problem>`.

```
Error: execution error at (global-chart/templates/cronjob.yaml:19:17): cronJobs.report.fromWorkload: references workload 'api', which does not exist in .Values.workloads
```

When a rule ties two keys, the message names both:

```
Error: execution error at (global-chart/templates/pdb.yaml:30:6): workloads.web.pdb.minAvailable: 1 allows no voluntary eviction with workloads.web.replicaCount: 1, so kubectl drain and cluster-autoscaler scale-down never finish on its node. Lower it, or set maxUnavailable: 0 instead to block evictions on purpose.
```

Fix the key the path names; the template file and line are the chart's, not
yours. A key removed in a major release fails the same way, naming its
replacement. The *Migration guide* sections of `CHANGELOG.md` cover each
major.

## Pointing an application repository at this guide

Put this in the application's AGENTS.md (or CLAUDE.md), with the chart
version the application pins:

```markdown
## Helm values

The values files in this repository configure global-chart <version>
(https://github.com/filippolmt/global-chart). Before editing them, read the
guide for that version:
https://github.com/filippolmt/global-chart/blob/global-chart-<version>/docs/values-authors/README.md
Every field and its description: charts/global-chart/values.schema.json at the
same tag. Do not work around a schema error or a render fail by moving values
to another field: fix the values path the error names. When you bump the chart
version, update the version in both links.
```
