# Changelog

All notable changes to this chart are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versioning follows [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Fixed

- **An `Orphan` ExternalSecret whose target is a chart-rendered Secret now fails
  at render** (issue #161, [ADR 0013](docs/adr/0013-an-owner-externalsecret-target-cannot-be-a-chart-secret.md)).
  `Orphan` clears the Secret's `data` down to its own keys, like `Owner`, so
  Helm and ESO overwrite each other on every upgrade and every refresh; 2.8.0
  caught only `Owner`. `Merge`, `CreateOrMerge` and `None` stay allowed. Two
  `Orphan` ExternalSecrets sharing one target now fail too.
- **Service shapes the API server rejects now fail at `helm lint` or at
  render** (issue #155). `service.type: ExternalName` is removed from the
  schema: the chart renders ports and a selector and no `spec.externalName`, so
  the Service was always rejected. An `extraPorts[].nodePort` on a Service that
  is not `NodePort` or `LoadBalancer` now fails at render, and so does an
  `extraPorts` entry repeating a port name or a port+protocol pair of the
  primary port or of another entry (a default primary port is 80/TCP named
  `http`).
- **Ingress and PDB values the API server rejects now fail at `helm lint`**
  (issue #156). `values.yaml` shipped `ingress.hosts[0].service.port: 0`, which
  counted as set and rendered `port.number: 0`; the line is gone, so a host
  takes its deployment's port, or 80 for a `service.name` backend. The schema
  now holds `ingress.hosts[].service.port` to 1–65535, requires at least one
  entry in `paths`, and restricts `pathType` to `Exact`, `Prefix` and
  `ImplementationSpecific`. A PDB `minAvailable` / `maxUnavailable` is an
  integer or a percentage string (`"25%"`): a digit string such as `"2"` is
  rejected, spell it `2`.
- **A mounted config file whose content starts with indentation renders**
  (issue #157). The ConfigMap value was a bare `|` block scalar, which takes its
  indentation from the first line: content such as `"  indented: first\nsecond:
  line"` (a YAML fragment, Python) ended the scalar early and failed with `did
  not find expected key`. Values are now `|2` block scalars, for `files` and
  `bundles` alike. A `files` entry with no `filename` or no `targetPath` now
  fails naming its values path, instead of a bare YAML parse error or a null
  `mountPath`.
- **`imagePullSecrets` items and a job's `restartPolicy` are validated by the
  schema** (issue #158). On deployments and jobs `imagePullSecrets` was a bare
  array, so `[regcred, 5]` passed lint and crashed the render with `wrong type
  for value`; its items now share `global.imagePullSecrets`' shape, a string or
  `{name}`. A job's `restartPolicy` takes `OnFailure` or `Never` only: `Always`
  passed lint and was rejected at apply. An item with no `name`, which failed
  at render with `imagePullSecrets must be a list of strings or objects with a
  'name' key.`, is now rejected by the schema instead.

## [2.8.0] — 2026-09-25

### Added

- **A hook can run as an `rbacs.roles` ServiceAccount in a `pre-install`,
  `pre-upgrade`, `pre-rollback` or `post-delete` phase** (ADR 0010). Helm applies the SA, Role and RoleBinding of
  an entry after the `pre-*` hooks, and deletes them before `post-delete`, so a
  hook bound to that SA used to find it missing, or without its rules. On a
  first install, or on the first Argo CD sync, the pod never scheduled. For every
  entry whose SA such a hook runs as, the chart now also renders hook copies
  under their own names: `<role>-hook`, `<binding>-hook`, and `<sa>-hook` when
  the entry creates the SA. If the entry creates the SA, the hook's pod runs as
  `<sa>-hook`. A Workload Identity / IRSA binding keyed on the SA name does not
  reach the copy; bind an SA created outside the release (`create: false`) to
  keep it. If the entry binds an existing SA, the hook keeps that SA and only the
  Role and RoleBinding are copied. A copy whose name truncates back onto the
  real one (a Role at 253 characters, a RoleBinding or SA at 63) fails the
  render. No values change.

- **Per-resource annotations on Deployments and ExternalSecrets** (issue #112).
  `deployments.<name>.annotations` sets the Deployment's own `metadata`
  annotations — distinct from `podAnnotations`, and not propagated to the
  Service, ServiceAccount, HPA or any other resource of the deployment.
  `externalSecrets.<name>.annotations` does the same for the ExternalSecret.
  Both merge over `global.commonAnnotations`, the resource's own winning on a
  shared key, so an Argo CD user can order the sync with
  `argocd.argoproj.io/sync-wave`. The hook-prerequisite copy of an
  ExternalSecret does **not** take them: it is a hook resource, ordered by hook
  phase and weight, and a sync-wave copied onto it would contradict that.
- **`backoffLimit` on hook Jobs, both scopes** (issue #113). A failing migration
  hook was retried six times, the Kubernetes default, before Helm saw the
  failure. No fallback from the deployment or `global`. `ttlSecondsAfterFinished`
  is deliberately not offered: a completed hook Job is kept as the record of
  what ran, a TTL deletion races `before-hook-creation`, and `deletePolicy:
  hook-succeeded` already covers cleanup. `parallelism` / `completions` are left
  out too: a hook is one run. The Job spec fields of hooks and cronjobs now
  render from one table (`jobSpecVerbatimFields`), so the two scopes of a kind cannot
  drift apart again.

### Changed

- **Behaviour change: a hook bound to a ServiceAccount the release creates runs
  as its hook copy `<sa>-hook`** (issue #141, ADR 0011, superseding ADR 0002).
  The copy of a deployment's chart-created SA used to share the real SA's name
  and was deleted after the hook. Under Argo CD, which runs `pre-install` on
  every sync, that deleted the **live** SA each time, and the running pods lost
  their bound tokens. The copy now has its own name. It is rendered for every
  hook of either scope bound to that SA in a `pre-install`, `pre-upgrade`,
  `pre-rollback` or `post-delete` phase, not only a deployment-level
  `pre-install`. So a root-level hook naming the deployment's SA, and a revision
  that adds a deployment with a `pre-upgrade` hook, now work. The copy carries
  the real SA's annotations and automount, and a copy name that truncates back
  onto the real one fails the render. A cronjob's own chart-created SA gets the
  same copy when a hook names it.
  **The pod loses an identity keyed on the
  SA name:** a Workload Identity / IRSA binding on
  `system:serviceaccount:<ns>:<sa>` does not reach `<sa>-hook`. To keep it,
  create the SA outside the release and bind it with `serviceAccount.create:
  false` and `name`. No values change.

- **Behaviour change: `autoscaling.enabled` with no active target fails at
  render** (issue #151,
  [ADR 0012](docs/adr/0012-autoscaling-enabled-requires-an-active-metric.md)).
  The Deployment drops `spec.replicas` whenever autoscaling is enabled, while
  the HPA rendered only with a positive CPU or memory target. With neither, no
  HPA rendered and Kubernetes ran **one** pod, ignoring `replicaCount` and
  `minReplicas`; `helm lint` passed. The render now fails, naming the
  deployment. A string target takes digits only: `"80%"`, which read as 0 and
  hit the same path, is rejected by the schema, as are a leading zero and a
  negative number. `0` and `""` still turn one metric off. The HPA and the
  validator read the active targets from one helper, `hpaActiveTargets`.

- **Behaviour change: a job's pod follows `automountServiceAccountToken`**
  (issue #154, [ADR 0014](docs/adr/0014-job-pod-automount-follows-the-inheritance-chain.md)).
  Hooks and cronjobs never rendered the pod-level field: a job's own value
  reached only a ServiceAccount the job creates, so a job running as its
  deployment's SA, or as the hook copy `<sa>-hook`, got the token anyway. The
  pod field now takes the job's own value, then, for a deployment-level job,
  the deployment's pod-level `automountServiceAccountToken`; with neither set
  it is omitted and the ServiceAccount decides, as before. A root-level job
  reads only its own value. The deployment's value is not carried into an SA
  the job creates: the pod field already wins over it.

- **A `pre-delete` hook reads the real Secret of its `externalSecrets`
  entries**, not the hook-prerequisite copy (ADR 0007, amended by ADR 0010).
  `pre-delete` runs before Helm deletes anything, so the real Secret is there;
  the copy only added an ExternalSecret to reconcile before the hook could
  start. An ExternalSecret referenced only by `pre-delete` hooks no longer gets
  a copy.

- **ServiceAccount resolution has one home** (issue #126), the new
  `_serviceaccount-helpers.tpl`. The `create` and `automount` defaults were
  re-derived in `serviceaccount.yaml`, `rbac.yaml`, `hook.yaml` and two helpers;
  every template now reads the resolved ServiceAccount instead. No rendered
  output changes.

### Fixed

- **An `Owner` ExternalSecret whose target is a Secret the chart renders now
  fails at render** (issue #153,
  [ADR 0013](docs/adr/0013-an-owner-externalsecret-target-cannot-be-a-chart-secret.md)).
  `externalSecrets.<key>` and `deployments.<key>.secret` both default to
  `<fullname>-<key>`, so naming an ExternalSecret after its deployment rendered
  one Secret owned by Helm and an ExternalSecret adopting it: Helm and ESO
  overwrote each other's `data`, and deleting the ExternalSecret
  garbage-collected the Helm Secret. The `Owner` target (the default policy) is
  now checked against every chart Secret, the `-hook-secret` prerequisite copy
  included. `Merge` and `None` stay allowed: Helm keeps the keys `Merge` adds.

- **An ExternalSecret's `target.creationPolicy` and `target.deletionPolicy`
  take ESO's values only**: `Owner`, `Orphan`, `Merge`, `None`,
  `CreateOrMerge`, and `Delete`, `Merge`, `Retain`. Any string passed `helm
  lint` and the ExternalSecret CRD rejected it at apply; the name collision
  checks, which branch on the policy, also read a typo such as `owner` as
  "not Owner".

- **A string PDB bound is a count or a percentage.** `pdb.minAvailable` and
  `pdb.maxUnavailable` took any string and printed it unquoted: `"two"` passed
  `helm lint` and the API server rejected it, and `"010"` reached it as the
  octal 8. A string now holds digits with no leading zero, optionally followed
  by `%` (`"25%"`, `"2"`).

- **A string hook `weight` with a leading zero is rejected by the schema**,
  both scopes. The weight arithmetic reads it with base detection, so `"010"`
  rendered `helm.sh/hook-weight: "8"` on the Job and `"3"` on its
  ServiceAccount, and the hook ran in a different order than written. A string
  weight now holds a plain integer (`"10"`, `"-5"`). `"007"`, which happened to
  read as 7, is rejected too.

- **Tolerations, host aliases, DNS options and KEDA credential references are
  checked by the schema** (issue #145). `tolerations[]`, `hostAliases[]` and
  `dnsConfig.options[]` (deployments and jobs, both scopes) and a
  TriggerAuthentication's `secretTargetRef[]` and `env[]` entries were open
  objects: a typo (`efect`, `hostname`, `keyy`) installed and was dropped by
  Kubernetes or KEDA, and a number in `tolerations[].value` rendered unquoted
  and was rejected at apply. They now reject an unknown key, and a
  toleration's `value` must be a string (`value: "1"`). A DNS option's `value`
  still takes a number, which the template prints and quotes.
  `extraContainers` and `extraInitContainers` stay pass-through: how much of a
  Container to admit is ADR 0006's open question (issue #148).

- **`additionalEnvs` on a deployment-level cronjob or hook is rejected**
  (issue #146). The schema declared it, but no template read it, so it was a
  silent no-op. Use the job's own `env`; the deployment's `additionalEnvs` is
  still inherited as before.

- **A number in a field Kubernetes types as a string is rejected by the schema**
  (issue #137), not by the API server at apply. `additionalEnvs[].value` and a
  job's `env[].value` (EnvVar.value, both scopes) and a KEDA trigger's
  `metadata` values (`map[string]string`) accepted a number, rendered it
  unquoted, and passed `helm lint`; the apply then failed. Quote the number
  (`value: "10"`). Values that set a number there were already broken at
  apply. An env entry now also rejects a key other than `name`, `value` and
  `valueFrom`: such a key used to install and be dropped by Kubernetes, so a
  typo like `valueFrm` left the variable empty. Fix the key, or remove it.

- **Large Job spec integers render in plain digits** — `activeDeadlineSeconds`,
  `ttlSecondsAfterFinished`, `backoffLimit`, `parallelism` and `completions`,
  on hooks and cronjobs. Helm reads a number from a values file as a float64,
  and `activeDeadlineSeconds: 10000000` rendered as `1e+07`, which the API
  server rejects for an integer field.
- **Every other integer from values renders in plain digits too** (issue #132).
  The same `1e+07` reached `replicas`, `revisionHistoryLimit`,
  `progressDeadlineSeconds` and `terminationGracePeriodSeconds` on Deployments;
  `startingDeadlineSeconds`, `successfulJobsHistoryLimit` and
  `failedJobsHistoryLimit` on cronjobs, both scopes; the HPA replica bounds; the
  PDB `minAvailable` / `maxUnavailable`; the HTTPRoute `weight`; and the
  ScaledObject replica counts and intervals. `--set` parses the number as an
  integer, so the defect showed only with a values file.
- **Numbers from values in string fields are no longer silently corrupted**
  (issue #132). The same exponent notation reached fields the API server
  accepts as strings, so nothing failed and the application read the wrong
  value: a ConfigMap value `LIMIT: 10000000` rendered `"1e+07"` (on the
  deployment ConfigMap and on its hook-prerequisite copy), a `dnsConfig.options`
  value the same, an ExternalSecret `remote.version` the same, and a numeric
  image tag `20240101` rendered the image `nginx:2.0240101e+07`. A whole number
  now prints as its digits and a fraction keeps its form (`1.5` stays `1.5`).
  A ConfigMap value set to `null`, which rendered as `"<nil>"`, now fails the
  render: set `""` for an empty value.
  Every number printed from values, in integer and string fields alike, now
  goes through one helper, `global-chart.printScalar`, ports included; the Job
  spec fields fixed above (#131) use the same helper instead of their own cast.
  An int-or-string value — a percentage PDB bound, a named `targetPort` —
  renders unchanged.
- **A `dnsConfig.options` value of `0` or `""` is no longer dropped** (issue
  #136). `ndots: 0` rendered as a bare `ndots`, and the resolver used `ndots:5`.
  An option now omits `value` only when the key is absent or null, on
  Deployments and on the cronjobs that inherit `dnsConfig`.
- **A fullname that can never be applied is now rejected** (issue #120). A
  dotted release name such as `my.app`, or a `fullnameOverride` like `My_App`,
  rendered container and Service names the API server rejects.
  `nameOverride` and `fullnameOverride` are now DNS-1123 subdomains in the
  schema (`""` still means no override). A render-time `fail` catches the rest,
  for releases that need it: a dot in the fullname when an enabled Deployment or
  a root-level hook names a container after it, and a leading digit when an
  enabled deployment renders a Service. A cronjob-only release with a dotted
  name keeps rendering. The fix is `fullnameOverride`. Every truncated name now
  also drops a trailing `.` or `_`, not only `-`. See
  [ADR 0009](docs/adr/0009-the-fullname-constraint-follows-what-the-release-renders.md).
- **A job naming its ServiceAccount twice, with different names, is now
  rejected** (issue #133). A hook or cronjob, in either scope, can name its
  ServiceAccount in `serviceAccountName` and in `serviceAccount.name`; when both
  were set to different values `serviceAccountName` won in silence, and with
  `serviceAccount.create: true` the chart created the SA under that name, with
  the annotations (a Workload Identity binding, say) the `serviceAccount` map
  meant for the other one. Values that were already contradictory now fail at
  render, naming the job and both values. The same name in both fields stays
  accepted, and `""` still counts as unset. The fix is to keep only one of the
  two fields, or to set the same name in both. Error messages about a hook or
  cronjob now all name it by its values path (`cronJobs.cleanup`,
  `deployments.api.hooks.pre-install.migrate`): the name collision messages
  used to say `root cronJob 'cleanup'` or `hook 'pre-install/migrate' in
  deployment 'api'`.
- **Every name collision message names its owners by values path** (issue
  #135), not only the jobs: `deployments.api` for `deployment 'api'`,
  `deployments.api.configMap` / `.secret`, their hook-prerequisite copies as
  `deployments.api.configMap (hook prerequisite copy)`, a mounted file as
  `deployments.api.mountedConfigFiles.files[0] ('app.conf')`, and
  `externalSecrets.app-env` / `kedaTriggerAuthentications.<key>` for the quoted
  keys. A pattern matched against the old wording has to follow.
- **`helm install`/`upgrade` warn below Helm 3.18.6** (issue #116). The schema
  closures of the four job composites need it, and older Helm ignored them in
  silence. `NOTES.txt` now says so; `helm template` and Argo CD do not show
  NOTES, so the README Prerequisites state the floor as well.
- **`rbacs.roles[].name` is now validated by the schema** (issue #121). It was
  any string, and it becomes the Role, the RoleBinding and — when
  `serviceAccount` has no `name` of its own — the ServiceAccount `<name>-sa`,
  which must be a DNS-1123 subdomain. `Reader_Role` with `serviceAccount: { create: true }`
  rendered, passed `helm lint`, and was rejected by the API server. The name is
  now a DNS-1123 subdomain of at most 253 characters, whether or not a
  `serviceAccount` sits next to it. The unreachable default
  `<fullname>-role-<index>` is removed from `rbac.yaml`: `name` was already
  required by the schema. See
  [ADR 0008](docs/adr/0008-rbac-role-name-is-a-required-dns-subdomain.md).
- **Service port names are now validated by the schema** (issue #118).
  `service.portName`, `service.extraPorts[].name` and a named `targetPort` (on
  the primary port and on each extra port) were any string, and they become the
  Service port names and the container port names, which Kubernetes validates as
  `IANA_SVC_NAME`. `http-management-api` rendered, passed `helm lint`, and was
  rejected by the API server. They are now held to that rule by a shared
  `$defs/ianaSvcName`: at most 15 characters, lowercase alphanumerics and `-`, at
  least one letter, no leading, trailing or doubled `-`. An empty `portName` or
  `targetPort` stays accepted: the API server takes it on a single-port Service.
  With `extraPorts` the Service is multi-port, and an empty `portName` is
  rejected: every port of a multi-port Service must be named.
- **`serviceAccount.name` is now validated by the schema, in every scope**
  (issue #123): deployments, hooks and cronjobs of both scopes, and
  `rbacs.roles[].serviceAccount`. It must be a DNS-1123 subdomain of at most 253
  characters, or `""`, which keeps meaning "the default name". `Web_SA` rendered,
  passed `helm lint`, and was rejected by the API server; it is now rejected at
  lint. A job's `serviceAccountName` is held to the same rule (`null` and `""`
  still mean unset). Only values that could never be applied are affected.
- **`rbacs.roles[].serviceAccount: {}` now creates the ServiceAccount**
  (issue #124). `{}` was read as absent, so the entry rendered a Role bound to
  no one, while `{ automount: false }` created `<name>-sa` and its RoleBinding.
  `{}` now means what it means for a deployment — a ServiceAccount with every
  default — and renders `<name>-sa`, the Role and the RoleBinding. An empty
  `name: ""`, which rendered a ServiceAccount with no name, now falls back to
  `<name>-sa` too.
  **Migration:** an entry that relied on `serviceAccount: {}` for "Role only"
  must drop the `serviceAccount` key.
- **Name collisions between `rbacs.roles` entries now fail at render**
  (issue #122): two entries with one `name`, `foo` next to `foo-role` (both
  yield the RoleBinding `foo-rolebinding`), and two long names whose default
  ServiceAccount truncates to the same 63 characters. The chart-created
  ServiceAccount is also checked against the deployment, hook and cronjob ones.
  All of these rendered, passed `helm lint`, and then overwrote each other or
  failed with "already exists" at install.
- **Two `kedaTriggerAuthentications` keys truncated to one name now fail at
  render** (issue #117). The second TriggerAuthentication overwrote the first
  at apply, and a ScaledObject meant for the first read the second's
  credentials.

### Migration guide from 2.7.x

> No values change shape. What changes is **which ServiceAccount a hook's pod
> runs as** in the copy phases, **whether a job's pod mounts its token**, and
> **which values the chart accepts**: values
> that rendered but could never be applied, or were ignored in silence, now
> fail at `helm lint` or at render. Run `helm lint` and then `helm template`
> (or `helm diff upgrade`) against your own values before upgrading — every
> case below shows up there.

#### 1. A hook bound to a chart-created ServiceAccount runs as `<sa>-hook` (HIGH if you rely on Workload Identity / IRSA)

A `pre-install`, `pre-upgrade`, `pre-rollback` or `post-delete` hook, in either
scope, whose ServiceAccount the release creates (a deployment's, an
`rbacs.roles` entry's, a cronjob's) now runs as the hook copy `<sa>-hook`
(ADR 0011). An identity bound to `system:serviceaccount:<ns>:<sa>` does not
reach it, so a migration that reads a cloud secret through that identity gets
a permission error.

**Who is affected:** hooks in those phases that inherit or name a SA the chart
creates, and rely on an identity keyed on the SA name.

**Action:** create the SA outside the release and bind it.

```yaml
deployments:
  app:
    serviceAccount:
      create: false
      name: app   # created by Terraform, say, with its IRSA / WI binding
```

#### 2. `rbacs.roles[].serviceAccount: {}` now creates the ServiceAccount (MEDIUM)

`{}` used to mean "Role only"; it now renders `<name>-sa` and its RoleBinding
(issue #124). **Action:** drop the `serviceAccount` key to keep a Role alone.

#### 3. Jobs of a deployment with pod-level `automountServiceAccountToken: false` lose the token (MEDIUM)

A deployment-level hook or cronjob now inherits the deployment's pod-level
`automountServiceAccountToken` (issue #154), whichever ServiceAccount it runs
as — its deployment's, the hook copy `<sa>-hook`, or one it names in
`serviceAccountName`. A job that calls the Kubernetes API sees a missing token
or a `403`.

**Who is affected:** only deployments that set pod-level
`automountServiceAccountToken: false` and have jobs needing the API.

**Action:** set it back on the job.

```yaml
deployments:
  app:
    automountServiceAccountToken: false
    cronJobs:
      reconcile:
        automountServiceAccountToken: true
```

#### 4. The schema rejects values that could never be applied (MEDIUM)

- **Numbers in string fields** (issues #137, #145): `additionalEnvs[].value`, a
  job's `env[].value`, a KEDA trigger's `metadata` values,
  `tolerations[].value`. They rendered unquoted and the apply failed.
  **Action:** quote them (`value: "10"`).
- **Unknown keys** in an env entry, a toleration, a host alias, a DNS option
  and a TriggerAuthentication `secretTargetRef` / `env` entry (issues #137,
  #145). Kubernetes or KEDA dropped them in silence. **Action:** fix the key
  the error names.
- **An HPA target that is not a plain number** (#151): `"80%"`, `"010"`, `-1`.
  `"80%"` read as 0 and switched the HPA off. **Action:** write `80`.
- **A string hook `weight` or PDB bound with a leading zero**, or a PDB bound
  that is not a count or a percentage: `"010"` read as octal 8. **Action:**
  drop the zero (`"10"`), write the percentage as `"25%"`.
- **An ExternalSecret policy outside ESO's enum** (`creationPolicy: owner`).
  **Action:** use ESO's spelling (`Owner`).
- **Names Kubernetes rejects**: `nameOverride` / `fullnameOverride` (#120),
  `rbacs.roles[].name` (#121), `serviceAccount.name` and a job's
  `serviceAccountName` (#123), Service port names and named `targetPort`s
  (#118). **Action:** use a DNS-1123 name, or a 15-character `IANA_SVC_NAME`
  for ports.
- **`additionalEnvs` on a deployment-level cronjob or hook** (#146): it never
  reached the manifest. **Action:** move it to the job's `env`.

#### 5. Contradictory values now fail at render (MEDIUM)

- Two `rbacs.roles` entries landing on one Role, RoleBinding or ServiceAccount
  (#122), two `kedaTriggerAuthentications` keys truncated to one name (#117), a
  hook copy whose name truncates back onto its real one (ADR 0010, ADR 0011).
- `autoscaling.enabled: true` with no positive CPU or memory target (#151).
  It rendered no HPA and one pod. Set a target, or disable autoscaling.
- A job naming its ServiceAccount twice with different names (#133).
- An `Owner` ExternalSecret whose target is a chart Secret, typically one named
  after a deployment that also declares `secret:` (#153): rename `target.name`,
  or drop `secret:` from the deployment.
- A ConfigMap value set to `null` (#132): set `""`.
- A dotted fullname with a Deployment or root hook, a leading digit with a
  Service (#120).

**Action:** the error names the values path; rename, or keep one of the two.

#### 6. A `pre-delete` hook reads the real Secret of its `externalSecrets` (LOW)

It used to read the hook copy (ADR 0010). The real Secret is still there when
`pre-delete` runs, so nothing to do unless you relied on the copy's name.

#### 7. Error messages name their owners by values path (LOW)

`deployments.api`, `cronJobs.cleanup`, not `deployment 'api'` (#133, #135).
**Action:** update any pattern matched against the old wording.

#### Migration checklist

- [ ] `helm lint` your values and fix every rejection (point 4)
- [ ] `helm template` your values and fix every render failure (point 5)
- [ ] Check which hooks run as `<sa>-hook`, and move identity-bound SAs outside the release (point 1)
- [ ] Look for `rbacs.roles[].serviceAccount: {}` (point 2)
- [ ] Look for jobs under a deployment with pod-level `automountServiceAccountToken: false` that need the API (point 3)
- [ ] Update CI patterns matched against error messages (point 7)
- [ ] Check Helm is 3.18.6 or newer, or the schema closures are ignored (issue #116)
- [ ] `helm diff upgrade`, then upgrade

---

## [2.7.0] — 2026-09-24

### Added

- **A hook can read a Secret produced by the release's own `externalSecrets`**
  (issue #110). The ExternalSecret is a normal resource, applied after the
  `pre-*` hooks, so a migration hook reading its Secret waited for something
  nothing created until the hook finished: `pending-install` until `--timeout`
  under Helm, a `PreSync` that never ends under Argo CD. Deployments, hooks and
  cronjobs now take `externalSecrets: [{name: <key>, mountPath?: <path>}]`,
  which references a key of the root `externalSecrets` map — as an `envFrom`
  source, or as a read-only volume with `mountPath`. A deployment's hooks and
  cronjobs inherit its list (`hasKey`; `[]` stops it). For every key a `pre-*`
  or `post-delete` hook references, the chart renders a hook-prerequisite copy
  of the ExternalSecret — same spec, its own target `<target>-hook`,
  `creationPolicy: Owner`, the `prereq` weight and delete policy — and the hook
  reads that Secret; the Deployment, cronjobs and every other hook read the real
  one. `post-delete` is there because it runs after the real ExternalSecret and
  its Secret are gone. Failing at render time rather than at apply: a key that
  `externalSecrets` does not define; a mounted key that is not a DNS-1123 label,
  mounted twice, or landing on a volume the pod declares; name collisions of the
  copy's ExternalSecret and Secret; two ExternalSecrets owning one target; a
  `Merge`/`None` ExternalSecret writing into the Secret a copy owns. See
  [ADR 0007](docs/adr/0007-hook-prerequisite-externalsecret-copy.md).

  `envFromSecrets` with the literal generated name keeps working, gets no copy
  and does not protect the first install. Migration: replace it with
  `externalSecrets: [{name: <key>}]`.

- **`activeDeadlineSeconds` on hook Jobs**, root and deployment level. A hook
  pod waiting for a Secret never reaches `Failed`, so `backoffLimit` does not
  bound it; before this only `helm --timeout` did.

### Changed

- **Two ExternalSecrets owning one target Secret now fail the render.** The
  collision check that covers the hook copy also registers every real
  ExternalSecret under `creationPolicy: Owner` (the default). Such a pair was
  already broken at runtime — ESO refuses the second owner with
  `ErrSecretIsOwned` — but it used to render. Targets under `Merge` or `None`
  are written into, not owned, and may still be shared.

- The ExternalSecret `spec` body moved into `renderExternalSecretSpec`, shared
  by the real resource and its hook copy. The rendered manifests are unchanged.

### Fixed

- **Map keys that become names are now validated by the schema** (issue #114).
  A key of `deployments`, `cronJobs`, `hooks`, `externalSecrets` or
  `kedaTriggerAuthentications` becomes part of a name Kubernetes or Helm
  validates, and nothing checked it: `App_Env` under `externalSecrets` rendered,
  passed `helm lint`, and was rejected at apply time, away from its cause. Each
  key is now held to what the tightest place it lands in accepts, the same in
  both scopes: a DNS-1123 label for `deployments` (at most 58 characters) and
  for every cronjob and hook key (at most 63); a lowercase Helm hook type for
  the keys of `hooks` and `deployments.<name>.hooks`; a DNS-1123 subdomain for
  `externalSecrets` and `kedaTriggerAuthentications`. Values that could never be
  applied are now rejected at `helm lint` / `helm install`. Two cases used to
  get *through* `helm install`, and are worth checking in existing values:
  - **An unknown hook type** (`pre-instal`) rendered, and Helm dropped the
    resource with an INFO log and exit 0 — the hook never ran. At deployment
    scope it also dropped the shared prereq ConfigMap/Secret, leaving the valid
    hooks pointing at a ConfigMap that did not exist. An uppercase type
    (`PRE-INSTALL`) is accepted by Helm but missed by the chart's case-sensitive
    checks, and yields an invalid name. Fix: spell the type as Helm lists it, in
    lowercase (`pre-install`, `post-upgrade`, `test`…).
  - **A `deployments` key of 59–63 characters** installed while the deployment
    had no hooks, and the install failed the moment one was added: the hook
    resources carry `<key>-hook` as their `app.kubernetes.io/component` label,
    over the 63 a label value allows. The cap is now 58 with or without hooks.
    Fix: shorten the key. It names the Deployment and its resources, so the
    upgrade replaces them under the new name rather than updating them in place.

---

## [2.6.1] — 2026-09-14

### Fixed

- **The release published without waiting for the tests.** `Release Charts` and
  `Helm CI` were two workflows on the same `push` to `main`, which GitHub starts
  in parallel: `chart-releaser` cut the release while the lint, unit-test,
  kubeconform, kube-linter and e2e jobs were still running — and cut it just the
  same when they failed. Publishing is the one irreversible step in the pipeline
  and it was the one with nothing in front of it. The release is now a job
  inside `Helm CI` with `needs: [lint-and-test, e2e]`, so a red check stops it,
  and it is gated on a push to `main` so a pull request never reaches it.

- **The packaged README was three changes out of date.** `helm-docs` runs from
  `make generate-docs` and nothing in CI checked its output, so
  `charts/global-chart/README.md` still carried the 2.5.1 badge, the previous
  chart description and the three dead `filippomerante` links that 2.6.0 had
  just removed from `Chart.yaml`. It went unnoticed while the file stayed out of
  the package; it became the front page of the chart the moment the fix below
  put it in. The README is regenerated, and CI now runs `make generate-docs` and
  fails when the result differs from what is committed — the same check the
  manifests have had all along.

- **The chart package carried no README.** `.helmignore` excluded `README.md`
  alongside the `README.md.gotmpl` it is generated from, so the published
  `.tgz` held only `Chart.yaml`, `values.yaml`, `values.schema.json` and the
  templates. The generated values reference — the whole output of
  `make generate-docs` — never reached the people it is written for:
  `helm show readme global-chart/global-chart` returned nothing and the
  Artifact Hub page showed no documentation at all. Only the `.gotmpl` template
  is excluded now. The README appears on Artifact Hub with the next published
  version; releases up to 2.6.0 stay as they are.

## [2.6.0] — 2026-09-14

### Fixed

- **`kubeVersion` promised a floor the chart cannot honour.** `Chart.yaml`
  declared `>=1.19.0-0`, so Helm let the chart install on clusters where it
  cannot work: the HPA renders `autoscaling/v2`, stable in 1.23, and the PDB
  renders `policy/v1`, stable in 1.21. On 1.19 the install failed at the API
  server with an unrecognised kind, far from the metadata that had allowed it.
  The floor is now `>=1.23.0-0`, with the two apiVersions that set it named
  beside it so the next reader can recompute it instead of trusting it. A
  cluster below 1.23 is now refused at install time, by the check that exists to
  refuse it; nothing changes at or above 1.23.

- **`home`, `sources` and the maintainer URL pointed at a user that does not
  exist.** All three named `github.com/filippomerante`, which is a 404 — the
  repository is `github.com/filippolmt/global-chart`. Those fields travel into
  the published `index.yaml` and into Artifact Hub, so every release so far has
  shipped three dead links. The chart `description` and `keywords` also lagged
  behind what the templates render: the description now names the
  multi-deployment shape, and `gateway-api` and `external-secrets` join the
  keywords.

- **Common and per-resource annotations were emitted as two YAML keys when they
  shared a name.** With `global.commonAnnotations.owner` and, say,
  `deployments.<name>.serviceAccount.annotations.owner` both set, the manifest
  carried `owner:` twice. Helm's parser is not strict and took the last one, so
  the effective value happened to be right; `kubeconform -strict` and any other
  strict consumer rejected the file outright. The two sources are now merged into
  one map, the per-resource value winning — an empty string included, which is how
  you blank a common annotation on one resource — on every resource that has both:
  ServiceAccounts, CronJobs, hook Jobs and the pod template's `podAnnotations`.
  On a resource where they collided the rendered annotations lose the duplicate
  line; elsewhere the merge only re-sorts the keys alphabetically.
  `podAnnotations` also wins over the `checksum/*` annotations, as it already
  did in practice. The three `helm.sh/hook*` annotations the chart emits itself
  are dropped from the merged map instead of being rendered twice: they govern
  hook ordering at runtime and the chart owns them.

- **`global.commonLabels` collided with per-resource labels the same way.** With
  `global.commonLabels.team` and `deployments.<name>.podLabels.team` both set,
  the pod template carried `team:` twice; the same happened between a common
  label and the chart's own `app.kubernetes.io/*` labels. The sources are now one
  merged map too. The precedence differs from the annotations by one step: the
  chart's identity labels win over `global.commonLabels`, because the selectors
  are built from them alone — a common label overwriting
  `app.kubernetes.io/name` used to leave the pod template no longer matching its
  own Deployment selector, which the API server rejects. `podLabels` still wins
  over a common label.

- **`hooks.<type>.<name>.annotations` is now rendered**, at the root level and
  under a deployment alike. The schema accepted the key and `hook.yaml` dropped
  it without a word — `cronJobs` rendered the same key all along. It lands on the
  hook Job, next to its `helm.sh/hook*` annotations.

- **A root-level `cronJobs.<name>` with no `serviceAccount` now gets the
  ServiceAccount its pod references.** It used to render
  `serviceAccountName: <release>-global-chart-<name>` and create nothing, so
  every Job the CronJob spawned failed to schedule with
  `serviceaccount "…" not found`. The manifest is valid and kubeconform passes:
  only a live cluster shows it. Root-level `hooks` already created the SA in
  that case; the two scopes now behave the same.

  If you already created a ServiceAccount with that exact generated name by
  hand, outside Helm, the install will now report `already exists`. Point the
  cronJob at it explicitly instead:

```yaml
cronJobs:
  cleanup:
    serviceAccount:
      name: my-existing-sa   # or: create: false
```

- **A job told `serviceAccount.create: false` with no name to bind no longer
  points its pod at a ServiceAccount nothing creates.** `serviceAccountName` is
  now omitted in that case and the pod runs as the namespace `default` — the
  only thing "do not create one, and here is no name" can honestly mean. Set
  `serviceAccount.name` (or `serviceAccountName`) to bind a specific existing SA.

- **Two chart-created ServiceAccounts can no longer share a name.** A root-level
  `cronJobs.cleanup` next to a `deployments.cleanup` generates
  `<release>-global-chart-cleanup` twice, and the install dies on `already
  exists` partway through the release. `validateNameCollisions` now fails the
  render instead, naming both sources. The hook-prerequisite SA copy of
  [ADR 0002] is untouched: it shares the real SA's name on purpose, and being a
  hook resource it never reaches the validator.

- **A `configMap` value that is a map or a list now renders as a string, so the
  ConfigMap is a manifest the API server accepts.** `ConfigMap.data` is
  `map[string]string`; the chart emitted a nested YAML mapping instead, and both the
  real ConfigMap and its hook-prerequisite copy were rejected at apply time with
  `got object, want null or string`. The value is now serialized with `toYaml` into a
  block scalar:

```yaml
deployments:
  backend:
    configMap:
      pool.yaml:
        min: 2
        max: 10
```

```yaml
data:
  pool.yaml: |-
    max: 10
    min: 2
```

  String, numeric and boolean values are untouched. `secret` was already correct
  (`toYaml | b64enc` yields a string). `tests/deployment-hooks-cronjobs.yaml` now
  carries a map, a list and a non-string secret value, so `make kubeconform` covers
  the branch at all four call sites.

- **`helm test` now has a pod to run.** `.helmignore` carried an unanchored
  `tests/` — meant for the helm-unittest suites at the chart root, but the
  pattern matches at any depth, so `templates/tests/test-connection.yaml` was
  stripped from the chart too. `helm test <release>` found no test hook and did
  nothing, while `NOTES.txt` told the user to run it. The pattern is anchored
  (`/tests/`) and the connection test ships again.

- **Two `mountedConfigFiles` entries can no longer collide into one ConfigMap.**
  `files` and `bundles[].files` render into a single name space
  (`<deployment>-md-cm-<name>`), so the same `name` on both sides produced two
  ConfigMaps under one name with different content, and the pod mounted
  whichever applied last. Both branches are now registered in the collision
  validator and `helm lint` fails, naming the two entries.

- **A long `mountedConfigFiles` name no longer renders a Deployment the API
  server rejects.** `name` feeds the pod volume name `md-cm-file-<name>`, a
  DNS-1123 label capped at 63 chars, and nothing bounded it: a 60-character name
  came out at 71 and the Deployment was refused on apply, far from its cause.
  The schema now bounds `name` at 52 chars and requires a DNS-1123 label, on
  `files` and on `bundles[].files` alike.

  **Breaking for values that were already invalid**: an uppercase or over-long
  `name` now fails `helm lint` instead of failing in the cluster. Rename the
  entry — the ConfigMap it generates is chart-internal and is not referenced
  from anywhere else.

- **A deployment's own ConfigMap or Secret can no longer be silently shadowed by a
  generated one.** The collision validator tracked only the hook-prerequisite
  copies, so a deployment named `<other>-md-cm-<file>` rendered a ConfigMap under
  the very name another deployment derived for a mounted config file — two
  manifests, one name, each valid on its own, and the apply kept the last. The
  same held for a deployment named `<other>-hook-secret` against a
  hook-prerequisite Secret. Every ConfigMap and Secret the chart generates is now
  registered, whatever derived it, and the error names both sides.

### Deprecated

- **`deployments.<name>.mountedConfigFiles.files[].mountPath`.** The key has
  never been read by any template: it is `targetPath` that sets where the file
  is mounted. It is marked deprecated in the schema and will be removed in the
  next major; setting it does nothing today and did nothing before.

### Changed

- **Nine `$defs` in `values.schema.json` no longer accept undeclared keys.**
  `deployment`, `networkPolicy`, `ingress`, `mountedConfigFiles` and
  `externalSecret` gain `additionalProperties: false`; the four job definitions
  `cronJob`, `deploymentCronJob`, `hookJob` and `deploymentHookJob` gain
  `unevaluatedProperties: false`. A key that no template reads under
  `deployments.<name>`, `cronJobs.<name>`, `hooks.<type>.<name>` or their
  deployment-level counterparts now stops install and upgrade instead of being
  silently ignored: `deployments.web.replicaz: 3` used to render a Deployment
  without a word. The remedy is to remove the key, or to fix the typo — the
  error names the path (`at '/deployments/web/replicaz'`). The four job
  definitions need **Helm >= 3.18.6**: below it `unevaluatedProperties` is
  ignored in silence and those four behave exactly as they do today, never
  worse. The five flat definitions use `additionalProperties: false` and hold on
  every Helm. Applying the same criterion to the rest of the file closed five
  more objects that are not definitions of their own: the entries of
  `ingress.tls`, of `ingress.hosts` and of a host's `paths`, a host's explicit
  `service` reference, and the entries of `rbacs.roles`. `probe` stays open on
  purpose, along with every other Kubernetes passthrough surface — the register
  is in the ADR. `$schema` moves from Draft 7 to Draft 2019-09, which is what
  `unevaluatedProperties` needs; nothing else in the file changes meaning
  between the two drafts, and a fork that `$ref`s one of these definitions from
  its own schema should follow. See [ADR 0006].

- **`cronJobs.<name>.serviceAccount.name`, `.automount`, `.annotations` and
  `.create: false` now do something.** The schema has always accepted them —
  they share `$defs/serviceAccount` with every other job scope — but
  `cronjob.yaml` read only `serviceAccount.create`, so the rest passed
  validation and was silently dropped. Root-level cronJobs and hooks now resolve
  their ServiceAccount through the same `jobServiceAccount` helper the
  deployment-level ones use.

- **`serviceAccountName` together with `serviceAccount.create: true` now names
  the ServiceAccount the chart creates**, in every job scope. Deployment-level
  jobs used to ignore the name and create the generated one instead; root-level
  hooks honoured it. They agree now, on the reading that does what the values
  say.

- **A hook `weight` written as a string must now look like an integer**
  (`^-?[0-9]+$`), in `hooks` and `deployments.<name>.hooks` alike. `weight: " 5"`
  or `weight: "5s"` used to pass the schema and render as weight **0** — silently,
  in the one field whose whole purpose is relative order. They are rejected at
  lint time now. Integers are untouched, and so is every canonical string:
  `"10"`, `"007"`, `"-5"`.

- **A hook `weight` written as a non-canonical string now renders the same
  number everywhere.** `weight: "007"` used to reach the hook Job's
  `helm.sh/hook-weight` verbatim while every resource derived from it — the
  hook's ServiceAccount, the prerequisite ConfigMap/Secret — coerced it with
  `int`, so one hook rendered `"007"` and `"2"` for what is the same weight.
  All four hook roles coerce now, and `"007"` renders `"7"`. Weights already
  written canonically (`10`, `"5"`, `-3`) are unaffected. The three
  `helm.sh/hook*` annotations come from a single `hookAnnotations` helper, which
  is also where the ordering invariant `prereq (w-7) < SA (w-5) < Job (w)` now
  lives — see [ADR 0004].

- **Documented: an explicit `deletePolicy` on a hook applies to the resources
  that hook owns, not to the shared plumbing.** Its Job and the ServiceAccount
  the chart creates for it honour it; the hook-prerequisite ConfigMap/Secret
  (shared by every hook of the deployment, so no single hook owns the choice)
  and the `pre-install` ServiceAccount copy of [ADR 0002] keep a fixed policy.
  No behaviour changed here — `CLAUDE.md` pattern 8 claimed otherwise and has
  been corrected.

- **The hook-prerequisite ConfigMap and Secret can no longer drift from the real
  ones.** Their `data` bodies must be byte-identical to what `configmap.yaml` and
  `secret.yaml` render — a hook Job that reads different values than the
  Deployment will get is a failure no manifest shows — yet `hook.yaml` re-derived
  both serialization rules inline. The two bodies now come from
  `renderConfigMapData` and `renderSecretData` in `_render-helpers.tpl`. Rendered
  output is unchanged; see [ADR 0005]. The tests that close the gap ship with it:
  the non-string branch (`map`/`slice` → `toYaml` for the ConfigMap, non-string →
  `toYaml | b64enc` for the Secret) was untested at all four call sites, and no
  test asserted `data` on the prerequisite copies at all.

- **Root-level `hooks` and `cronJobs` now render their pod spec through the same
  module as the deployment-level ones.** `hook.yaml` and `cronjob.yaml` each
  carried their own copy of the pod spec for root-level jobs — imagePullSecrets
  chain, hostAliases, securityContext, dnsConfig, container, volumes,
  nodeSelector, affinity, tolerations, restartPolicy — so a field added to the
  pod spec had to be added in three places, and the three had already drifted in
  field order. Root-level jobs now pass no `deploy` to `jobPodSpec` (renamed from
  `inheritedJobPodSpec`, since it is no longer only for the inheriting scope):
  that scope simply *is* the "nothing to inherit from" case, which is how
  `jobServiceAccount` was widened in this same cycle. Nothing is inherited that
  was not inherited before, no key becomes active, and no field gains a fallback
  it did not already have; see [ADR 0001].

  **The only visible effect is field order** inside the pod spec of root-level
  hooks: `serviceAccountName` now comes after `volumes`, `resources` after `env`,
  and `restartPolicy` last, matching every other job the chart renders. Same
  keys, same values, same semantics — a `helm diff` across the upgrade shows the
  reordering and nothing else.

- **The defaults of a Service's primary port have one home.** `port` (80),
  `portName` (`http`), `protocol` (`TCP`) and `targetPort` (which follows the
  port's name) were each re-derived inline in up to four templates, and
  `service.enabled` in five, with three different idioms. They now come from
  `servicePrimaryPort` and `serviceEnabled`; `serviceTargetPort` is gone, its
  one field folded into the tuple. Rendered output is unchanged — this closes
  the half of issue #82 that the container-port fix left open, on the Service
  side.

  `deploymentEnabled` now takes the deployment map directly
  (`include "global-chart.deploymentEnabled" $deploy`) instead of wrapping it in
  `(dict "deploy" $deploy)`, matching `serviceEnabled` and `containerPorts`. It
  is a chart-internal helper and no values key is affected; only a fork that
  calls it from its own template needs the one-line update.

- **The four job definitions in `values.schema.json` are composed instead of
  copied.** `cronJob`, `deploymentCronJob`, `hookJob` and `deploymentHookJob`
  were four hand-written lists: all four repeated the same 24 pod/container
  properties, the two cron ones the same 13 `batch/v1` scheduling properties,
  the two hook ones the same two Helm hook properties, and the scope keys were
  repeated in pairs as well. They are now `allOf` over five `$defs` —
  `jobCommon`, `cronJobSpec`, `hookJobSpec`, `rootJobSpec` and
  `deploymentJobSpec` — so a new job field is declared once, on the axis it
  belongs to. No key changes meaning: every value accepted before is accepted
  now, every value rejected before is rejected now, and the rendered manifests
  are byte-identical. Only a fork that `$ref`s one of the four definitions from
  its own schema sees anything, and those `$ref`s still resolve.

[ADR 0001]: docs/adr/0001-keep-root-and-deployment-job-rendering-separate.md
[ADR 0002]: docs/adr/0002-hook-prerequisite-serviceaccount-copy.md
[ADR 0004]: docs/adr/0004-one-module-for-hook-lifecycle-annotations.md
[ADR 0005]: docs/adr/0005-one-module-for-configmap-and-secret-data.md
[ADR 0006]: docs/adr/0006-close-the-schema-defs-that-declare-their-properties.md

### Migration guide from 2.5.x

> No values change shape and no schema key is removed. What changes is **which
> ServiceAccount a job's pod runs as**, in four cases, and **which values the
> schema accepts**: a key no template reads used to be ignored and is now
> rejected (point 6). Run `helm lint` and then `helm template` (or `helm diff
> upgrade`) against your own values before upgrading — every case below shows up
> there.

#### 1. A root `cronJobs` entry keyed like a deployment now fails the render (HIGH)

```yaml
deployments:
  cleanup: { image: nginx }
cronJobs:
  cleanup: { image: busybox, schedule: "0 0 * * *" }   # render now fails
```

Both generate `<release>-global-chart-cleanup`, and both now emit a
ServiceAccount under that name — two manifests, one name, an install that dies
partway with `already exists`. `validateNameCollisions` stops it at render time
instead.

This is the one case that used to *work*: the CronJob referenced the name the
deployment's SA happened to occupy, so its pods borrowed that identity.

**Who is affected:** anyone with a root-level `cronJobs` key equal to a
`deployments` key.

**Action:** keep the borrowed identity explicitly, or rename one of the two.

```yaml
cronJobs:
  cleanup:
    serviceAccount:
      create: false
      name: my-release-global-chart-cleanup   # the deployment's SA, as before
```

#### 2. Root `cronJobs` now get a ServiceAccount of their own (MEDIUM)

Every other root-level cronJob referenced a SA that no manifest created, so its
Jobs never scheduled (`serviceaccount "…" not found`). The chart now creates it.

**Who is affected:** anyone whose root-level cronJobs never ran — and anyone who
worked around it by creating that SA by hand, outside Helm. The hand-made one
now collides (`already exists`).

**Action:** if you created the SA yourself, either delete it and let the chart
own it (check its annotations first — IRSA/Workload Identity bindings live
there), or bind it explicitly with `serviceAccount: { create: false, name: … }`.
If your cronJob needs RBAC, remember the new SA has none: the RoleBinding that
used to name your hand-made SA must name the chart's.

#### 3. `serviceAccountName` + `serviceAccount.create: true` now names the created SA (MEDIUM)

```yaml
deployments:
  api:
    hooks:
      pre-install:
        migrate:
          serviceAccountName: custom-sa
          serviceAccount: { create: true }
```

Deployment-level jobs used to ignore `custom-sa` and create the generated name
instead; root-level hooks honoured it. They agree now, on `custom-sa`.

**Who is affected:** deployment-level hooks/cronJobs that set both keys. The SA
they run as changes name.

**Action:** point any RoleBinding/ClusterRoleBinding at the new name, or drop
`serviceAccountName` to keep the generated one.

#### 4. `serviceAccount.create: false` with no name now means the namespace default (MEDIUM)

The pod used to carry `serviceAccountName: <generated>` — a SA nothing creates —
so it could only schedule if something outside Helm had created that exact name.
The field is now omitted and the pod runs as `default`.

**Who is affected:** jobs with `serviceAccount: { create: false }` and no
`name`/`serviceAccountName`, and no deployment SA to inherit.

**Action:** if an out-of-band SA was the point, name it:
`serviceAccount: { create: false, name: my-sa }`.

#### 5. A hook `weight` string that is not an integer now fails validation (LOW)

`weight: " 5"` and `weight: "5s"` used to pass the schema and render as weight
**0**, which silently reordered the hook against its own prerequisites. They are
rejected at lint time now.

**Who is affected:** values with a `weight` string containing anything but digits
and a leading `-`. `helm lint` names the field.

**Action:** write the integer you meant — `weight: 5`, or `weight: "5"`.

#### 6. A key no template reads now fails validation (MEDIUM)

```yaml
deployments:
  web:
    image: nginx:1.25
    replicaz: 3        # meant replicaCount; used to render a Deployment in silence
```

Nine `$defs` — `deployment`, `networkPolicy`, `ingress`, `mountedConfigFiles`,
`externalSecret` and the four job definitions — used to accept any key and drop
the ones they did not declare. They now reject them, naming the path:
`at '/deployments/web/replicaz'`. Five nested objects that declare their
properties the same way went with them: the entries of `ingress.tls`, of
`ingress.hosts` and of a host's `paths`, a host's explicit `service` reference,
and the entries of `rbacs.roles`.

Kubernetes passthrough surfaces are deliberately untouched and still take
anything — probes, `volumes`, `networkPolicy.ingress`/`egress`,
`dataFrom[].sourceRef`, the `resources` maps, PolicyRules, HTTPRoute filters.
See [ADR 0006] for the criterion.

**Who is affected:** values carrying a key the chart never read — almost always a
typo, occasionally a key left behind by an older chart version. It is a lint
failure, not a render difference, so no manifest changes for anyone it does not
affect.

**Action:** run `helm lint` and remove the key, or fix the typo the error names.

**One caveat on Helm's side.** The four job definitions (`cronJobs.<name>`,
`hooks.<type>.<name>` and their deployment-level counterparts) close with
`unevaluatedProperties`, which **Helm below 3.18.6 ignores in silence**. On an
older Helm those four behave exactly as they did on 2.5.x — never worse, but a
typo there will not be caught until you upgrade Helm. The other definitions use
`additionalProperties` and hold on every Helm.

#### 7. Clusters below Kubernetes 1.23 are now refused at install time (MEDIUM)

```
Error: chart requires kubeVersion: >=1.23.0-0 which is incompatible with Kubernetes v1.22.0
```

`Chart.yaml` declared `>=1.19.0-0`, a floor the chart could not honour: the HPA
renders `autoscaling/v2`, stable in 1.23, and the PDB renders `policy/v1`,
stable in 1.21. On an older cluster Helm waved the install through and the API
server rejected the manifest instead, far from the metadata that had allowed
it. The floor now matches what the templates render.

**Who is affected:** anyone on a cluster below 1.23. A release using only
Deployments and Services worked there and is now turned away by the check,
because the metadata cannot express "1.21 unless you enable the HPA".

**Action:** upgrade the cluster, or stay on 2.5.x. Overriding the check with
`helm install --no-verify`-style flags is not worth it — the moment such a
release enables `autoscaling` or `podDisruptionBudget`, the API server rejects
the manifest.

#### Migration checklist

- [ ] `helm lint` your values and remove any key the schema now rejects (point 6)
- [ ] `helm template` your values and diff the `ServiceAccount` documents against 2.5.x
- [ ] Resolve any name collision the render now reports (point 1)
- [ ] Check RBAC for every ServiceAccount whose name changed or appeared (points 2-4)
- [ ] Check IRSA / Workload Identity annotations on hand-made SAs you hand over to the chart
- [ ] `helm lint` your values for a `weight` string that is not an integer (point 5)
- [ ] Check your cluster is 1.23 or newer (point 7)
- [ ] `helm diff upgrade`, then upgrade

---

## [2.5.1] — 2026-08-08

### Fixed

- A numeric `deployments.<name>.service.targetPort` is now the container's
  declared port ([#82]). It used to be accepted and then ignored: `containerPort`
  came from `service.port`, so the only working configuration was
  `targetPort == port`. The port *name* (`service.portName`, default `http`)
  went with it, which is what actually broke — a probe or another Service
  targeting the port by name resolved to a port the application does not listen
  on, and the default `targetPort: http` resolved back to `service.port`,
  undoing any attempt to point elsewhere.

```yaml
deployments:
  web:
    service:
      port: 80          # Service exposes 80
      targetPort: 8080  # container declares and names 8080
```

  Reviewing that fix turned up two more instances of the same defect — a Service
  port whose `targetPort` names something no container port declares, which
  Kubernetes accepts in silence and leaves without endpoints:

- **`service.targetPort` no longer defaults to the literal `http`**, but to
  `service.portName`. Setting only `portName: api` used to produce a Service
  targeting `http` while the container port was named `api`, so a single option
  was enough to get a Service with no endpoints.

- **A numeric `targetPort` under `service.extraPorts` is now declared on the
  container**, named after its Service port. Previously the pod declared exactly
  one port, so a named `targetPort` in `extraPorts` could never resolve. Naming
  them makes that form usable:

```yaml
extraPorts:
  - { name: gevent, port: 8072, targetPort: 8072 }  # declares container port 8072 as "gevent"
  - { name: ws,     port: 8073, targetPort: gevent }  # now resolves
```

- **A named `targetPort` that resolves to nothing now fails the render**
  (`validateServiceTargetPorts`), instead of installing a Service that quietly
  serves no traffic. The check caught the chart's own
  `tests/service-extra-ports.yaml` fixture, which had been shipping the broken
  shape.

  `templates/_render-helpers.tpl` gains `containerPorts`, the single source of
  truth for the pod side of the Service: `deployment.yaml` renders it and the
  validator checks names against it, so the two cannot drift again — that drift
  is what all three bugs were.

  `make e2e` now installs every shape of Service port on a real cluster and
  asserts the EndpointSlice ports, which is the only check that can see this
  class of bug: the manifests are valid, kubeconform passes, Kubernetes creates
  the Service without complaint, and the port simply never gets an endpoint.

  Nothing changes for a release that never set a numeric `targetPort` and never
  customised `portName`. Releases that did were already broken; their pod spec
  changes, which costs one rollout on upgrade. A release relying on a named
  `targetPort` that never resolved now fails at install with an actionable
  message rather than serving nothing.

### Documentation

- `README.md` gains a section on the immutable `spec.selector` ([#83]).
  `app.kubernetes.io/name` is the **chart** name, not the application's — a
  generic chart has no application name to use, and the application's identity
  is carried by `helm.sh/chart`, the release name, and the deployment key.
  Because the label sits in the selector, `nameOverride` has to be decided
  before the first install: changing it later fails the upgrade with
  `field is immutable` and the Deployment must be deleted and recreated. The
  same applies to renaming a key under `deployments`, which lands in
  `app.kubernetes.io/component`. The default is unchanged — correcting it would
  break every existing release for a cosmetic gain.

[#82]: https://github.com/filippolmt/global-chart/issues/82
[#83]: https://github.com/filippolmt/global-chart/issues/83

---

## [2.5.0] — 2026-08-04

### Added

- `property` and `version` on `externalSecrets.<name>.remote` and
  `externalSecrets.<name>.data[].remote`. `property` is a gjson path that selects
  a single key out of a remote secret whose payload is a JSON bundle — previously
  the only way to get one key out of a bundle was to pull the whole thing and
  reshape it with `target.template` + `fromJson`. `version` pins a version of the
  remote secret instead of the provider default (`latest` on Google Secret
  Manager):

```yaml
externalSecrets:
  app:
    secretstore: { kind: ClusterSecretStore, name: gcp-store }
    data:
      - secretkey: DB_PASSWORD
        remote: { key: apps/prod/bundle, property: db_password }
      - secretkey: API_TOKEN
        remote: { key: apps/prod/bundle, property: api_token, version: "3" }
```

  Unlike the three strategy fields the chart applies no default to either — ESO
  defaults them at the CRD level — so both are omitted from the rendered
  `remoteRef` when the key is absent. Presence is decided by `hasKey`, not
  truthiness: an explicit `property: ""` is the user's input and is passed
  through rather than silently dropped. `version` accepts a string or a number
  and is quoted on render, so the natural `version: 3` works as well as
  `version: "3"` — the same leniency `image.tag` already has.
  `dataFrom[].extract` already accepted both, since it is rendered verbatim.
  Additive and backwards compatible.

---

## [2.4.0] — 2026-08-03

### Added

- `externalSecrets.<name>.target.template` and `.target.immutable`. `template`
  is passed through verbatim, so ESO's own templating survives untouched and the
  chart cannot drift from the upstream schema — this is what shapes a generated
  value into the file a workload expects:

```yaml
    target:
      immutable: false
      template:
        engineVersion: v2
        data:
          .htpasswd: '{{ htpasswd "stage" .password "bcrypt" }}'
```

  `target.manifest` is deliberately not exposed: it creates a custom resource
  *instead of* a Secret, so its interaction with the always-emitted `target.name`
  and `creationPolicy` needs runtime verification against ESO that the current
  e2e cluster (KEDA only) cannot provide.

### Fixed

- `externalSecrets.<name>.secretstore` is no longer mandatory when every
  `dataFrom` entry carries its own `sourceRef`. The chart demanded a
  spec-level store on every ExternalSecret, but `secretStoreRef` is optional in
  the CRD: an ExternalSecret backed by an ESO *generator* has no store to point
  at, and one whose entries each carry a per-item `sourceRef.storeRef` already
  resolves its own. Both forms were unrenderable.

```yaml
externalSecrets:
  basicauth:
    # no secretstore: the generator produces the value
    dataFrom:
      - sourceRef:
          generatorRef:
            apiVersion: generators.external-secrets.io/v1alpha1
            kind: Password
            name: stage-basicauth
```

  The store stays mandatory for every other form. A `dataFrom` where only some
  entries carry a `sourceRef` still fails, and so does an empty `dataFrom: []` —
  it has no entry that could resolve a store, and letting it through would
  render a store-less, data-less ExternalSecret.

---

## [2.3.0] — 2026-08-02

### Added
- KEDA event-driven autoscaling: `deployments.<name>.keda` renders a
  `ScaledObject`, and the root-level `kedaTriggerAuthentications` map renders
  `TriggerAuthentication` resources shared by any deployment's triggers. Scaling
  on a queue, a broker or any of KEDA's ~70 scalers no longer needs a second
  chart alongside this one.

```yaml
kedaTriggerAuthentications:
  sqs-auth:
    secretTargetRef:
      - { parameter: awsAccessKeyID, name: aws-credentials, key: AWS_ACCESS_KEY_ID }

deployments:
  worker:
    image: myapp:v2
    keda:
      enabled: true
      minReplicaCount: 0            # scale to zero between bursts
      maxReplicaCount: 20
      pollingInterval: 15
      annotations:                  # operational pause lever
        autoscaling.keda.sh/paused-replicas: "0"
      triggers:
        - type: aws-sqs-queue
          metadata:
            queueURL: https://sqs.eu-west-1.amazonaws.com/000000000000/jobs
            queueLength: "10"
            awsRegion: eu-west-1
          authenticationRef:
            name: sqs-auth          # key of kedaTriggerAuthentications
```

  `authenticationRef.name` takes the **key** of `kedaTriggerAuthentications`, not
  the rendered name: the chart rewrites it to `{release}-{chart}-{key}`, which
  values cannot know in advance. A name that is not a key in the map is passed
  through unchanged, so a `TriggerAuthentication` managed outside the chart can
  still be referenced.

  `keda` and `autoscaling` are mutually exclusive on the same deployment —
  enabling both fails the render. KEDA creates and owns its own HPA for the
  ScaledObject; a chart-rendered HPA on the same Deployment would fight it.

  The templates require the `keda.sh/v1alpha1` CRDs and say so with an actionable
  error when they are missing. Rendering a KEDA scenario offline (`helm template`)
  needs `--api-versions keda.sh/v1alpha1`.

  See `docs/adr/0003-keda-alongside-hpa.md`.

  A Deployment with `keda.enabled` omits `spec.replicas`, exactly as one with
  `autoscaling.enabled` already did: the autoscaler owns the field, and emitting
  it would make every `helm upgrade` overwrite the live replica count — with
  `minReplicaCount: 0`, waking a workload that was deliberately scaled to zero.
  `replicaCount` is inert on a deployment with either autoscaler enabled.

  **Nothing changes for existing `autoscaling` users**; the guard is extended,
  not introduced.

---

## [2.2.0] — 2026-07-25

### Added
- `deployments.<name>.command` and `deployments.<name>.args` (arrays of strings).
  Override the image `ENTRYPOINT` / `CMD` on the Deployment's main container,
  matching what `cronJobs` and `hooks` already supported. This makes it possible
  to run several workloads from a single image — e.g. a web server and a
  background worker — without a separate image or an in-image entrypoint
  dispatcher. Both fields are omitted from the pod spec when unset or empty
  (behavior unchanged). Resolves #72.

```yaml
deployments:
  web:
    image: myapp:v2                            # runs the image CMD (uvicorn)
  worker:
    image: myapp:v2
    command: ["python", "-m", "app.worker"]
    args: ["--concurrency", "5"]
```

  **Not inherited.** A deployment's `hooks` and `cronJobs` do *not* pick up its
  `command` / `args`: a migration hook inheriting `python -m app.worker` would
  silently run the worker instead of the migration. Set them explicitly on the
  hook or cronjob.

### Changed
- `values.schema.json`: `args` is now typed as an array of strings on cronjobs
  and hooks too (it was an untyped array). No working configuration changes — a
  numeric `args` entry already produced a manifest the API server rejects; the
  error now surfaces at `helm lint` / install time instead.

### Fixed
- A deployment-level `pre-install` hook can now run under a ServiceAccount the
  chart creates. Helm creates normal resources **after** `pre-install` hooks, so
  the hook Job used to reference a ServiceAccount that did not exist yet, could
  never schedule its pod, and left the release stuck in `pending-install`:

  ```
  Error creating: pods "<release>-<deployment>-pre-install-migration-" is forbidden:
  error looking up service account <ns>/<sa-name>: serviceaccount "<sa-name>" not found
  ```

  The deployment's ServiceAccount is now duplicated as a hook-prerequisite copy —
  same name, annotations and automount — alongside the ConfigMap/Secret copies
  that already existed for the same reason. Resolves #71.

```yaml
deployments:
  app:
    serviceAccount:
      create: true          # chart-managed, e.g. with Workload Identity annotations
    hooks:
      pre-install:
        migration:
          command: ["sh", "-c"]
          args: ["./migrate.sh"]
```

  The copy is annotated `helm.sh/hook: pre-install`, weighted
  `minPreInstallJobWeight - 5` (invariant `prereq w-7 < SA w-5 < Job w`) and
  deleted with `hook-succeeded,hook-failed`, so it lives only for the duration of
  the hook phase and never collides with the real ServiceAccount. It is emitted
  only when a `pre-install` hook actually binds the deployment's chart-created SA
  — a hook with its own `serviceAccountName`, or a deployment with
  `serviceAccount.create: false`, renders exactly as before.
  See `docs/adr/0002-hook-prerequisite-serviceaccount-copy.md`.

- Derived hook weights are no longer floored at 0. Helm allows negative hook
  weights, and clamping meant that a hook Job with a negative weight ran *before*
  the resources it depends on — its prerequisite ConfigMap/Secret and its
  ServiceAccount — reintroducing the very failure the weight ordering prevents.
  A hook with `weight: -3` now gets prereqs at `-10` and an SA at `-8` instead of
  both at `0`. Non-negative weights render exactly as before.

- Hook plumbing resources no longer survive `helm uninstall`. Hook resources are
  not part of the release manifest, so Helm never removes them: the deployment's
  hook-prerequisite ConfigMap **and Secret** — the latter holding the deployment's
  secret data — plus chart-created hook ServiceAccounts were left behind on every
  release, and accumulated across install/uninstall cycles. Their default delete
  policy is now `before-hook-creation,hook-succeeded`, so they are removed once
  the hook phase they serve completes. Hook **Jobs** keep the previous
  `before-hook-creation` default: a completed hook Job is the record of what ran.
  An explicit `deletePolicy` on the hook still overrides all of it.

### Notes
- Two cases remain unsupported by design:
  - a deployment added **during an upgrade** with `serviceAccount.create: true`
    and a `pre-upgrade` hook — the chart cannot tell at template time that the
    deployment is new. Bind a pre-existing SA (`create: false` + `name`) or move
    the job to `pre-install`.
  - a **root-level** hook (`.Values.hooks`) whose explicit `serviceAccountName`
    points at a chart-created deployment SA. Root-level hooks are standalone
    (ADR 0001); an explicit name is taken to mean an externally-managed SA.

---

## [2.1.0] — 2026-07-16

### Added
- Pod-level `deployments.<name>.automountServiceAccountToken` (boolean). Sets
  `automountServiceAccountToken` on the Deployment pod spec, letting a pod force
  (or opt out of) SA-token mounting independently of the ServiceAccount object's
  own setting. This is the only lever when the Deployment binds an
  **externally-managed** ServiceAccount (`serviceAccount.create: false`) whose
  object has `automountServiceAccountToken: false` — the chart doesn't manage
  that SA, so its automount value is inert and the pod otherwise gets no token.
  Opt-in: the field is omitted from the pod spec when unset (behavior unchanged).
  Resolves #73.

```yaml
deployments:
  controller:
    image: myapp/controller:v1
    serviceAccount:
      create: false
      name: external-workload-identity-sa   # has automountServiceAccountToken: false
    automountServiceAccountToken: true       # force the token mount at pod level
```

---

## [2.0.0] — 2026-06-28

### Added
- `externalSecrets.<name>.data` (list form): many remote keys collapsed into a
  single `ExternalSecret` → one `Secret` → one `envFromSecrets` reference,
  instead of one `ExternalSecret` per key.
- `externalSecrets.<name>.dataFrom` support (`extract` / `find`), rendered
  verbatim into `spec.dataFrom`. `data` and `dataFrom` may be set together —
  both are rendered, matching the external-secrets.io CRD.
- The single-key form (`remote` + `secretkey`) is used only when neither `data`
  nor `dataFrom` is set, and is unchanged / fully backward compatible. Combining
  it with `data`/`dataFrom` now fails with a clear error instead of silently
  dropping the named key.

```yaml
externalSecrets:
  app:
    secretstore: { kind: ClusterSecretStore, name: my-store }
    target: { name: app-secrets }
    data:
      - { secretkey: DB_PASSWORD, remote: { key: MY_DB_PASSWORD } }
      - { secretkey: API_TOKEN,  remote: { key: MY_API_TOKEN } }
  app-bulk:
    secretstore: { kind: ClusterSecretStore, name: my-store }
    dataFrom:
      - find: { name: { regexp: "^APP_.*" } }
```

### Changed
- Removed `appVersion` from `Chart.yaml`. This is a generic, reusable chart that
  deploys arbitrary workloads, so there is no single application version to pin.
- The `app.kubernetes.io/version` label is now emitted only when set — it is no
  longer hardcoded to the chart's `appVersion`. Consumers that want it can set
  it via `global.commonLabels` (e.g. `app.kubernetes.io/version: "2.3.4"`).

### ⚠️ Breaking — rendered-output change
- **`app.kubernetes.io/version` is no longer present on rendered objects by
  default.** Every resource previously carried this recommended label set to the
  chart's `appVersion`; after upgrading it disappears unless you set it yourself.
- **Impact:** dashboards, alerting rules, cost-allocation, and any `kubectl`/
  tooling queries that *filter on* `app.kubernetes.io/version` return empty or
  mismatched results after upgrade. **Pod/Service selectors are NOT affected** —
  they only ever matched `name`/`instance`/`component`, so rollouts are safe.
- **Migration:** if you relied on the label, re-add it explicitly via
  `global.commonLabels`:
  ```yaml
  global:
    commonLabels:
      app.kubernetes.io/version: "<your-app-version>"
  ```

---

## [1.7.0] — 2026-05-31

### Added
- HTTPRoute template (`templates/httproute.yaml`) supporting Gateway API v1
- Top-level `.Values.httpRoute` block: `parentRefs`, `hostnames`, `rules` (matches/filters/backendRefs/timeouts)
- Filter types: `RequestRedirect`, `URLRewrite`, `RequestHeaderModifier`, `ResponseHeaderModifier`, `RequestMirror`, `ExtensionRef`
- Multi-backend weighted routing for canary deployments
- Shared backend resolution helper `global-chart.resolveBackend` (used by both Ingress and HTTPRoute)
- kubeconform validation extended to `gateway.networking.k8s.io` schemas via `datreeio/CRDs-catalog`
- 4 lint scenarios: `tests/httproute-basic.yaml`, `tests/httproute-canary.yaml`, `tests/httproute-filters.yaml`, `tests/bad-values/httproute-conflict.yaml`
- 2 helm-unittest suites: `httproute_test.yaml` (rendering), `httproute_validation_test.yaml` (failure cases)

### Changed
- `templates/ingress.yaml` backend resolution refactored to call `global-chart.resolveBackend` (behavior-preserving — all existing tests pass unchanged)
- `templates/httproute.yaml` renders `parentRefs` and `matches` via `toYaml` passthrough (verbatim Gateway API structures) instead of field-by-field, mirroring Helm's own `helm create` HTTPRoute scaffold. The chart no longer re-implements the Gateway API field shape: per-field defaults (path `type`/`value`) are applied by the Gateway API CRD, and new match fields work with no template change. Only `backendRefs` stays field-by-field — that is where the chart transforms input (deployment name → Service via `resolveBackend`).

### Validation
- Schema sets `additionalProperties: false` on every nested `httpRoute` object (rule, matches, path, headers, queryParams, backendRefs, service, parentRefs, timeouts), so a misspelled key (e.g. `timeouts.requestTimeout` instead of `request`) is rejected at lint time instead of silently dropped. `filters` stay open by design (passthrough of arbitrary Gateway API filter bodies).
- `parentRefs[].port` and `backendRefs[].service.port` are bounded to `1–65535` (matching deployment service ports); `0`/out-of-range is rejected at lint time, not at apply time.
- `queryParams` match items now require `value` (like `headers`), preventing a rendered `value: null` that the Gateway API rejects.
- `matches[]` items require at least one of path/headers/queryParams/method (`minProperties: 1`), rejecting an empty match `{}`.

### Notes
- Gateway API v1 CRDs MUST be installed in the cluster; the chart does not create the Gateway resource (platform-managed)
- `.Values.ingress.enabled: true` and `.Values.httpRoute.enabled: true` are mutually exclusive — enabling both fails template render

### Migration: Ingress → HTTPRoute

| Ingress field                          | HTTPRoute equivalent                               | Notes                                          |
|----------------------------------------|-----------------------------------------------------|------------------------------------------------|
| `ingress.className`                    | `httpRoute.parentRefs[].name` (Gateway name)       | Gateway is platform-managed, not chart-rendered |
| `ingress.tls[].secretName`             | Configured on the Gateway listener (out of chart scope) | Use `parentRefs[].sectionName` to bind HTTPS listener |
| `ingress.hosts[].host`                 | `httpRoute.hostnames[]`                            | Multiple hostnames per HTTPRoute supported      |
| `ingress.hosts[].paths[].path`         | `httpRoute.rules[].matches[].path.value`           |                                                |
| `ingress.hosts[].paths[].pathType`     | `httpRoute.rules[].matches[].path.type`            | `Prefix` → `PathPrefix`; `Exact` → `Exact`     |
| `ingress.hosts[].deployment`           | `httpRoute.rules[].backendRefs[].deployment`       | Same resolution semantics                       |
| `ingress.hosts[].service.{name,port}`  | `httpRoute.rules[].backendRefs[].service.{name,port}` | Same                                         |
| nginx-ingress canary annotations       | `httpRoute.rules[].backendRefs[].weight`           | Native traffic split                            |
| nginx `rewrite-target` annotation      | `httpRoute.rules[].filters[].URLRewrite`           | Native filter                                   |
| nginx `permanent-redirect` annotation  | `httpRoute.rules[].filters[].RequestRedirect`      | Native filter                                   |

---

## [1.6.2] — 2026-05-31

### Changed

#### Internal: resource-name helper consolidation

Pure refactor — rendered manifests are byte-identical. The `printf | trunc` naming rules that were duplicated inline between the resource templates and the collision validator now live in five helpers in `_helpers.tpl`, each the single home for its name (and its truncation constant):

- **`global-chart.rootCronJobName`** / **`global-chart.deploymentCronJobName`** — CronJob names (trunc 52).
- **`global-chart.deploymentHookName`** — deployment-level hook Job name (single trunc 63 over the full 4-part name).
- **`global-chart.hookPrereqConfigName`** / **`global-chart.hookPrereqSecretName`** — hook-prerequisite ConfigMap/Secret names (trunc 63).

`cronjob.yaml`, `hook.yaml` and `_validate-helpers.tpl` all call these helpers, so the collision validator can no longer drift from the names the templates emit.

As part of this, `validateNameCollisions` previously computed the deployment-level hook Job name by truncating `deploymentFullname` first and re-truncating after appending `-<hookType>-<jobName>`, whereas `hook.yaml` truncates the full 4-part name once. The two forms only ever differ at a trailing-dash truncation boundary — i.e. for names Kubernetes itself would reject — so the collision **verdict** was never wrong for any valid input; the divergence was a latent inconsistency, not an observable bug. Routing both sites through `deploymentHookName` removes it.

---

## [1.6.1] — 2026-05-31

### Changed

#### Internal: job helper deduplication (issues #54, #55)

Pure refactor — rendered manifests are byte-identical; error messages unchanged.

- **`global-chart.jobImageString`** (`_job-helpers.tpl`): unifies the image-resolution choice (`explicit image > deploy.image > fromDeployment lookup+fail`) previously duplicated across four inline blocks in `cronjob.yaml` and `hook.yaml` (root + deployment-level). The `errCtx` argument preserves the exact `fromDeployment` failure messages.
- **`global-chart.jobServiceAccount`** (`_job-helpers.tpl`): unifies the deployment-level ServiceAccount resolution (name/create/automount/annotations) previously duplicated near-verbatim across `hook.yaml` PART 2 and `cronjob.yaml` PART 2. Returns a JSON object consumed via `fromJson`.
- Removed a dead `serviceAccount.automountServiceAccountToken` branch in the hook SA logic — the key is rejected by `values.schema.json` (`additionalProperties: false`), so it was unreachable. Automount is controlled by the job-level `automountServiceAccountToken` and the SA-map `automount` keys, unchanged.

Follow-ups resolved: #56 (`deploymentMetadata` helper) closed as won't-do; #57 (`renderJob` collapse) recorded as a deliberate non-decision in [ADR-0001](docs/adr/0001-keep-root-and-deployment-job-rendering-separate.md).

---

## [1.6.0] — 2026-05-21

### Added

#### Multi-port Services (issue #52)

- **`service.extraPorts`**: list of additional ports rendered on the same Service after the primary port. Unblocks workloads needing multiple ports on the same Pod selector (Odoo HTTP+gevent, Redis client+TLS, gRPC sidecars, exporters).
- Schema enforces required `[name, port, targetPort]` per item with `additionalProperties: false`. Optional: `protocol` (TCP/UDP/SCTP, default TCP), `appProtocol`, `nodePort` (30000-32767).

```yaml
deployments:
  odoo:
    service:
      port: 8069
      targetPort: 8069
      portName: odoo
      extraPorts:
        - name: gevent
          port: 8072
          targetPort: 8072
          appProtocol: http
        - name: metrics
          port: 9090
          targetPort: metrics
```

### Compatibility

- Backward compatible: Services without `extraPorts` render byte-for-byte identical manifests.

---

## [1.5.0] — 2026-05-08

### Added

#### CronJob hardening (issue #48)

- **CronJob spec fields**: `timeZone` (k8s ≥1.27), `suspend`, `startingDeadlineSeconds`.
- **jobTemplate.spec fields**: `backoffLimit`, `ttlSecondsAfterFinished`, `activeDeadlineSeconds`, `parallelism`, `completions`.
- Applied to both root-level (`.Values.cronJobs`) and deployment-level (`.Values.deployments.<name>.cronJobs`) cronJobs.

```yaml
cronJobs:
  cleanup:
    schedule: "0 2 * * *"
    timeZone: "Europe/Rome"
    backoffLimit: 3
    ttlSecondsAfterFinished: 600     # GC finished Jobs (avoids etcd bloat)
    activeDeadlineSeconds: 900       # kill runaway Jobs
    suspend: false
```

#### Deployment graceful shutdown (issue erredi #6)

- **Container `lifecycle`** (preStop / postStart) on deployments.
- **Pod `terminationGracePeriodSeconds`** on deployments.

```yaml
deployments:
  fast-api:
    image: myapp:v1
    terminationGracePeriodSeconds: 30
    lifecycle:
      preStop:
        exec:
          command: ["/bin/sh", "-c", "sleep 5"]
```

#### Inheritance opt-out toggles

- `inheritDeploymentSecret: false` and `inheritDeploymentConfigMap: false` on deployment-level cronjobs/hooks. Defaults `true`. Allows narrow-scope cronjobs to break envFrom inheritance, limiting secret leak surface.

```yaml
deployments:
  fast-api:
    secret:
      DB_PASSWORD: "..."
      MAILJET_KEY: "..."
    cronJobs:
      narrow-scope-job:
        schedule: "*/10 * * * *"
        inheritDeploymentSecret: false
        envFromSecrets: ["only-this-token"]
```

### Fixed

- **Empty `metadata:` blocks in CronJob output (issue #48)**. `jobTemplate.metadata` and `jobTemplate.spec.template.metadata` are now wrapped in conditional rendering. Previously emitted bare `metadata:` keys when `commonAnnotations` was empty, flagged by strict linters (kubeval, polaris).

### Changed

- **Schema validation tightened**: `cronJob.completions` and `deploymentCronJob.completions` now require `minimum: 1` (was `0`). Kubernetes Jobs reject `completions: 0` at apply time; schema now catches this earlier.

### Documentation

- `CLAUDE.md`: clarify root-vs-deployment-level cronJob/hook inheritance asymmetry; document new opt-out toggles.
- `values.yaml`: commented hardening examples on both cronJob locations.

### Migration

No breaking changes. All new fields are opt-in. Upgrade is a drop-in replacement for 1.4.x.

---

## [1.4.0] — 2026-03-17

### Migration guide from 1.3.x

> **This release contains behavioral breaking changes.** Read the migration guide carefully before running `helm upgrade`.

#### 1. Hook/CronJob SA inheritance now defaults to `create: true` (HIGH)

Deployment-level hooks and cronjobs now inherit the deployment's ServiceAccount by default. Previously, if the deployment didn't have an explicit `serviceAccount` block, hooks/cronjobs created their own SA.

**Who is affected:** all deployment-level hooks/cronjobs where the parent deployment does not explicitly set `serviceAccount.create`.

**Impact:** the hook/cronjob now runs with the deployment's SA. If RBAC differs, permissions may change.

**Action:** to preserve old behavior, explicitly set `serviceAccountName` on the hook/cronjob:

```yaml
deployments:
  backend:
    image: myapp:v2
    hooks:
      pre-upgrade:
        migrate:
          command: ["./migrate.sh"]
          serviceAccountName: "my-custom-sa"  # Override inheritance
```

#### 2. Legacy volume key precedence flipped (HIGH — edge case)

For legacy-format volumes, `secret.secretName` (the canonical Kubernetes key) now takes priority over the non-standard `secret.name` alias when both are present. Same for `persistentVolumeClaim.claimName` vs `.name`.

**Who is affected:** only users specifying BOTH `secret.name` and `secret.secretName` with different values (extremely rare).

**Action:** use only the canonical key (`secretName` / `claimName`). Remove the `name` alias if present:

```yaml
# Before (ambiguous — which one wins?)
volumes:
  - name: creds
    type: secret
    secret:
      name: old-secret         # Remove this
      secretName: new-secret   # Keep this (now wins)

# After (unambiguous)
volumes:
  - name: creds
    type: secret
    secret:
      secretName: new-secret
```

#### 3. Hook weight calculation changed (MEDIUM)

Hook SA weight is now computed as `jobWeight - 5` (was hardcoded `"5"`). Prerequisite ConfigMap/Secret weight is `minJobWeight - 7` (was hardcoded `"3"`).

For the default case (weight=10): SA=5, prereq=3 — **no change**. Only differs with custom `weight` overrides.

**Who is affected:** users with custom `weight` on hooks.

**Action:** run `helm template` and verify hook execution order after upgrade.

#### 4. `values.schema.json` added (CONDITIONAL)

A JSON Schema Draft 7 is now included. Helm uses it to validate values during `helm install/upgrade/lint`. Values with unknown top-level keys or incorrect types will be rejected.

**Who is affected:** users with non-standard top-level keys in values or values with incorrect types.

**Action:** run `helm lint` with your values before upgrading to see if schema validation catches anything. Fix any reported issues.

#### Migration checklist

- [ ] Read the points above and verify applicability
- [ ] Audit RBAC for deployment-level hooks/cronjobs (point 1)
- [ ] Check legacy volume specs for dual `name`/`secretName` usage (point 2)
- [ ] If using custom hook weights, verify execution order (point 3)
- [ ] Run `helm lint -f your-values.yaml` to test schema validation (point 4)
- [ ] Run `helm diff upgrade` to inspect all differences before applying
- [ ] Schedule the upgrade during a maintenance window
- [ ] Run `helm upgrade`

---

### Added

- **global.commonLabels** — opt-in shared labels applied to all resource metadata via the labels helper
- **global.commonAnnotations** — opt-in shared annotations applied to all resource metadata
- **Service annotations** — per-service `service.annotations` merged with `global.commonAnnotations` (service-specific wins on conflict)
- **JSON Schema Draft 7** — `values.schema.json` for input validation and IDE autocomplete
- **Name collision detection** — `validate.yaml` + `_validate-helpers.tpl` fail fast when truncation creates duplicate resource names
- **Ingress validation** — template fails with clear error when ingress host references a disabled deployment or a deployment with `service.enabled: false`
- **kubeconform** — CI step validates all generated manifests against K8s 1.29 schema
- **kube-linter** — CI step with `addAllBuiltIn: true` and documented exclusions
- **Bad-values validation** — CI step verifying schema correctly rejects invalid values
- **Docker pre-pull** — CI pre-pulls Docker images with 3 retries for resilience
- 90+ new unit tests (312 total across 17 suites), including negative `failedTemplate` tests

### Changed

- **Helper decomposition** — `_helpers.tpl` split into `_image-helpers.tpl`, `_job-helpers.tpl`, `_render-helpers.tpl`, `_validate-helpers.tpl` (~260 lines deduplication)
- **`inheritedJobPodSpec` shared helper** — eliminates duplication between deployment-level hook and cronjob pod spec rendering
- **Hook SA weight** — derived from Job weight (`jobWeight - 5`, min 0) instead of hardcoded "5"
- **Hook prerequisite weight** — derived from min Job weight (`minJobWeight - 7`, min 0) instead of hardcoded "3"
- **SA inheritance** — `deploySA.create` defaults to `true` via `hasKey/ternary`, matching `serviceaccount.yaml` behavior
- **Image tag/digest** — `toString` before `trim` to safely handle numeric tags (e.g., `tag: 1.25`)
- **Legacy volume precedence** — canonical K8s keys (`secretName`, `claimName`) now take priority over non-standard aliases (`name`)
- **Service annotations** — `deepCopy` before `merge` to avoid mutating `.Values`
- **restartPolicy** — null-safe with `default "Never"` fallback for empty/null values
- **renderVolume** — `required` guard on volume `name` field for clear error messages
- **Makefile** — `$(pwd)` → `$(CURDIR)` for consistency; new `validate-bad-values` target

### Fixed

- **CronJob SA null** — `serviceAccountName: null` now correctly falls back to job fullname
- **Schema completeness** — added `metadataPolicy`, `target.name`, `volumeMounts`, `initContainers`, `serviceAccountAnnotations`, `env`, `claims`, `mountPath`, `mountedConfigFiles` items schemas, `ingress.tls` items schema
- **Schema accuracy** — removed phantom `podAnnotations` and `suspend` from job definitions; removed dead `additionalEnvs` from root-level job definitions; `imagePullSecrets` accepts both strings and objects; `resources` allows custom types (GPU, ephemeral-storage)

---

## [1.3.0] — 2026-03-13

### Migration guide from 1.2.x

> **This release contains no blocking breaking changes**, but includes behavioral changes that may cause pod restarts or rendering differences. Read carefully before running `helm upgrade`.

#### 1. Expected rolling restart on first upgrade

The upgrade adds new annotations and labels to pod templates, which Kubernetes interprets as a spec change → rolling restart:

| Change | Effect |
|--------|--------|
| Added `checksum/secret` in pod annotations | Deployment pods are recreated on first upgrade |
| Added `app.kubernetes.io/version` label on all resources | Metadata labels change (not selectors, no impact on existing ReplicaSets) |

**Action:** schedule the upgrade during a maintenance window. After the first upgrade, subsequent restarts only happen when configMap/secret/mountedConfigFiles actually change.

#### 2. CronJob/Hook inheritance fix (potential behavior change)

Previous versions had a bug: explicitly setting an empty field (`nodeSelector: {}`, `tolerations: []`, `affinity: {}`, `imagePullSecrets: []`) on a deployment-level CronJob or Hook **did not override** the parent deployment value — it inherited it anyway.

This is now fixed: an explicit empty value **overrides** inheritance.

**Who is affected:** only users who explicitly set empty fields on deployment-level CronJob/Hook while the parent deployment has those fields populated. If you don't use hooks/cronJobs inside deployments, there is no impact.

**Action:** review your values for deployment-level CronJob/Hook. If you relied on the buggy behavior (empty field still inheriting from parent), remove the field to preserve inheritance.

```yaml
# Before (1.2.x) — empty nodeSelector inherited from deployment (bug)
deployments:
  backend:
    nodeSelector:
      disktype: ssd
    cronJobs:
      cleanup:
        nodeSelector: {}  # Bug: inherited disktype: ssd

# After (1.3.0) — empty nodeSelector correctly overrides
deployments:
  backend:
    nodeSelector:
      disktype: ssd
    cronJobs:
      cleanup:
        nodeSelector: {}  # Correct: no nodeSelector
        # To inherit: remove the nodeSelector line entirely
```

#### 3. Default resources for CronJob/Hook are now configurable

Default resources (100m CPU, 128Mi memory) for CronJobs and Hooks are **no longer hardcoded** in templates. They are read from `defaults.resources` in values.yaml.

The default value in values.yaml is identical to the previous hardcoded value, so **no change unless you override `defaults`**. If you override `defaults: {}` without specifying `resources`, CronJobs/Hooks without explicit resources will have no resource requests.

**Action:** none, unless you completely override the `defaults` section.

#### 4. Volumes: native Kubernetes support (no change required)

Volumes now accept both native Kubernetes spec and the legacy `.type` format. The legacy format continues to work without modifications.

```yaml
# Legacy format (still works)
volumes:
  - name: data
    type: emptyDir

# Native format (new, recommended)
volumes:
  - name: data
    emptyDir: {}
  - name: certs
    csi:
      driver: secrets-store.csi.k8s.io
```

**Action:** no migration required. Gradually adopting the native format for new volumes is recommended.

#### 5. Global values (optional, no change required)

New `global` section in values.yaml to share `imageRegistry` and `imagePullSecrets` across all resources. Completely opt-in.

**Action:** none. To centralize registry or pull secrets, add:

```yaml
global:
  imageRegistry: registry.example.com
  imagePullSecrets:
    - name: my-regcred
```

#### Migration checklist

- [ ] Read the points above and verify applicability
- [ ] Verify that deployment-level CronJob/Hook do not depend on the inheritance bug (point 2)
- [ ] Schedule the upgrade during a maintenance window (point 1)
- [ ] Run `helm diff upgrade` to inspect differences before applying
- [ ] Run `helm upgrade`
- [ ] Verify that pods restart correctly

---

### Added

- **PodDisruptionBudget** — new `pdb.yaml` template, enable per deployment with `pdb.enabled: true` and `minAvailable`/`maxUnavailable`
- **NetworkPolicy** — new `networkpolicy.yaml` template, enable per deployment with `networkPolicy.enabled: true` and ingress/egress rules
- **Helm test** — `helm test <release>` verifies connectivity to the first enabled service (`templates/tests/test-connection.yaml`)
- **Deployment strategy** — configurable `strategy` (RollingUpdate/Recreate) per deployment
- **revisionHistoryLimit** — optional field per deployment
- **progressDeadlineSeconds** — optional field per deployment
- **topologySpreadConstraints** — optional field per deployment
- **Global values** — `global.imageRegistry` (shared registry prefix) and `global.imagePullSecrets` (fallback pull secrets)
- **Native volume spec** — volumes now accept native Kubernetes spec directly (hostPath, CSI, downwardAPI, projected, etc.) alongside the legacy `.type` format
- **Configurable default resources** — `defaults.resources` section in values.yaml for CronJob/Hook without explicit resources
- **Secret checksum** — `checksum/secret` annotation in pod template for automatic restart when secrets change
- **Version label** — `app.kubernetes.io/version` added to all labels (deployment, hook, common)
- **hostAliases and dnsConfig for root CronJob** — added for parity with root Hook and deployment-level CronJob
- **dnsConfig for root Hook** — added for parity with deployment-level Hook
- **NOTES.txt** — sections for Hooks, PDB, and NetworkPolicy in post-install output
- **values.yaml documentation** — complete documentation for strategy, revisionHistoryLimit, progressDeadlineSeconds, topologySpreadConstraints, pdb, networkPolicy, native volumes
- **Chart.yaml** — added keywords (pdb, network-policy, hpa, autoscaling) and maintainer URL

### Changed

- **imageString helper** — now accepts a dict with `global` context to support `global.imageRegistry`. Backward compatible with direct invocation
- **imagePullSecrets** — extended fallback chain: deployment/job-level → global.imagePullSecrets (in deployment, cronjob, hook)
- **Default resources CronJob/Hook** — moved from hardcoded in template to `defaults.resources` in values.yaml (same value: 100m CPU, 128Mi memory)
- **renderVolume helper** — new centralized helper for volume rendering, used by deployment, cronjob, and hook
- **HPA validation** — `minReplicas` and `maxReplicas` now use `required()` for a clear error when omitted with HPA enabled

### Fixed

- **CronJob deployment-level inheritance** — `nodeSelector`, `affinity`, `tolerations`, `imagePullSecrets` with explicit empty value now correctly override parent deployment (switched from `if not` to `hasKey`/`ternary`)
- **Hook deployment-level inheritance** — same fix for the same 4 fields
- **Resources null** — the `resources` field is no longer rendered as `resources: null` when not specified in deployment

### Removed

- **Dead ingress code** — removed all `semverCompare` code for Kubernetes <1.19 in `ingress.yaml` (chart already requires `kubeVersion: >=1.19.0-0`)

---

## [1.2.1] — 2026-03-05

### Added

- `enabled` flag support on all templates (deployment, service, serviceaccount, hpa, configmap, secret, mounted-configmap, cronjob, hook, NOTES.txt)

---

## [1.2.0] — 2026-03-04

### Added

- Complete test suite (14 suites, 174 tests)
- Template improvements and Makefile enhancements

---

## [1.1.0] — 2026-02-28

### Changed

- ServiceAccount handling update and version bump

---

## [1.0.0] — 2026-02-15

### Added

- Initial release with multi-deployment support
- Deployment, Service, Ingress, CronJob, Hook, ExternalSecret, RBAC
- Inheritance pattern for deployment-level Hook/CronJob
