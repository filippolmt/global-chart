---
status: accepted
amended: 2026-09-14
---

# Keep root-level and deployment-level job rendering separate

> **Amended 2026-09-14** — the pod spec joined the shared helpers. The decision
> itself stands (no `renderJob(scope=…)` collapse); what changed is where the
> line between "shared logic" and "scope-specific scaffolding" falls. See *The
> pod spec was widened the same way* below, and the criterion added to
> *Considered options*.

`cronjob.yaml` and `hook.yaml` each carry two parallel sections — PART 1 for
root-level jobs (`.Values.cronJobs` / `.Values.hooks`) and PART 2 for
deployment-level jobs (`.Values.deployments.<name>.cronJobs` / `.hooks`) — that
look structurally similar (~300 lines of apparent duplication). We deliberately
**do not** collapse them into a single `scope`-parameterized `renderJob` module.

The two sections encode a genuine **semantic difference**, not copy-paste:
root-level jobs are standalone (no inheritance; image via `fromDeployment` or
explicit; their own SA), while deployment-level jobs inherit image, ConfigMap,
Secret, ServiceAccount, dnsConfig, nodeSelector, tolerations and affinity from
their parent deployment, and add hook-prerequisite ConfigMap/Secret copies with
a weight-ordering invariant (`prereq w-7 < SA w-5 < Job w`). Merging them behind
one interface would trade readability for DRY and create a leaky abstraction in
a templating language with no debugger and whitespace-sensitive output.

The genuinely-shared, identical logic has already been extracted into deep
helpers — `jobPodSpec` (pod spec), `jobImageString` (image resolution)
and `jobServiceAccount` (SA resolution, every scope) in `_job-helpers.tpl`
(`jobServiceAccount` has since moved to `_serviceaccount-helpers.tpl`, with the
other ServiceAccount resolvers — issue #126).
`jobServiceAccount` covered only deployment-level jobs until 2026-09: PART 1 of
both templates resolved the SA inline, and the two root scopes had drifted into
different answers (a root cronJob referenced a SA nothing created). Root-level
jobs simply pass no `deploy` — that scope *is* the "no deployment SA applies"
case the helper already handled — so this widened the shared logic without
adding a `scope` parameter, which is what this ADR rejects.

The **pod spec** was widened the same way, and for the same reason (2026-09-14).
This ADR originally counted the ~80 lines of pod spec in each PART 1 as
"scope-specific scaffolding, clearer read inline". It was not: it was a third
implementation of one composition — the same field sequence rendered by the same
leaf helpers — and the three had already drifted in field order, with
`serviceAccountName`, `restartPolicy` and `resources` in different positions in
each. A field added to the pod spec had to be added three times. Root-level jobs
now pass no `deploy` to `jobPodSpec` (renamed from `inheritedJobPodSpec`): with
no deployment to inherit from, each field resolves to the job's own value —
`imagePullSecrets` alone then falls back to `global.imagePullSecrets`, exactly as
it did inline. No field gains a fallback it did not have, no inheritance is
introduced, and no `scope` parameter: the helper's single `kind` parameter
(`hook` | `cronjob`) distinguishes the two job kinds, which is orthogonal to
scope. The cost paid once: the field order of root-level **hooks**
changed to the shared one. Same keys, same values.

What remains in PART 1 / PART 2 is the scope-specific scaffolding — the
`range` over the values, the names, the metadata, the hook annotations, the
CronJob `spec` fields — which is clearer read inline.

## Considered options

- **Collapse into `renderJob(scope=root|deployment)`** — rejected. The leverage
  (fewer lines) does not justify the risk to the weight invariant and the
  inheritance asymmetry, both of which must render byte-identically across the
  unit-test suite. A future maintainer debugging a weight or inheritance bug is
  better served by two explicit sections than one branchy mega-helper.
- **Extract only the truly-shared logic into helpers** — chosen and done
  (issues #54, #55), and widened in 2026-09 to cover the SA resolution and the
  pod spec of root-level jobs. The dividing line is not the scope but the
  question "is this one rule with two answers, or two rules?": a rule whose root
  answer falls out of the deployment-level one by passing no `deploy` belongs in
  the helper. Only a rule that needs a `scope` flag to branch stays inline.

## Consequences

- Some parallel scaffolding remains duplicated between PART 1 and PART 2; this
  is accepted.
- The pod spec of every job the chart renders now has a single interface, so a
  pod-level field (`topologySpreadConstraints`, say) is added in one place and
  reaches all four call sites at once — including the two that would otherwise
  be forgotten.
- Architecture reviews should stop re-suggesting the `renderJob` collapse. If
  the trade-off is ever revisited, supersede this ADR rather than silently
  collapsing.
