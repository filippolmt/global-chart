---
status: accepted
---

# Keep root-level and deployment-level job rendering separate

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
helpers — `inheritedJobPodSpec` (pod spec), `jobImageString` (image resolution)
and `jobServiceAccount` (deployment-level SA resolution) in `_job-helpers.tpl`.
What remains in PART 1 / PART 2 is the scope-specific scaffolding, which is
clearer read inline.

## Considered options

- **Collapse into `renderJob(scope=root|deployment)`** — rejected. The leverage
  (fewer lines) does not justify the risk to the weight invariant and the
  inheritance asymmetry, both of which must render byte-identically across the
  unit-test suite. A future maintainer debugging a weight or inheritance bug is
  better served by two explicit sections than one branchy mega-helper.
- **Extract only the truly-shared logic into helpers** — chosen and done
  (issues #54, #55).

## Consequences

- Some parallel scaffolding remains duplicated between PART 1 and PART 2; this
  is accepted.
- Architecture reviews should stop re-suggesting the `renderJob` collapse. If
  the trade-off is ever revisited, supersede this ADR rather than silently
  collapsing.
