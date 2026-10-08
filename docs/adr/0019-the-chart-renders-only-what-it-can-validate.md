---
status: accepted
---

# The chart renders only what it can validate

The chart serves about ten internal applications, deployed both by Argo CD and
by GitLab pipelines that run `helm`. Today their values are written by the
maintainer. The goal is that developers edit them with the help of an LLM: a
*values author* (see `CONTEXT.md`) who does not know the chart's internal rules
and learns them only from what the chart rejects and what it describes. That
reader decides the chart's scope.

**A workload enters the chart when its pod spec goes through the same helpers
and the same validation as the Deployment's.** Today that means Deployments,
CronJobs and hook Jobs. A future StatefulSet would likely qualify. An object
the chart cannot validate does not: it belongs in another chart or in the
application's own manifests.

**The chart has no free-form manifest field** (`extraObjects`,
`rawResources`, `extraManifests` or similar). A values author blocked by a
`fail` or by the closed schema moves the rejected block to the field that
accepts anything. One such field would bypass every rule the schema and the
templates enforce, in every release that uses it.

**`--skip-schema-validation` is not used by an application's CI.** ADR 0017
keeps it as the way out when Kubernetes adds a field before the chart lists it.
It remains a manual step taken by the maintainer, for one release, until a
chart release lists the field. A pipeline that passes the flag on every run is
the free-form field again, behind a flag.

## Considered Options

- **A list of supported kinds instead of a criterion.** Rejected: every new
  request would reopen the list. The criterion answers the request by itself.
- **bjw-s `app-template`.** It was not evaluated when the chart was started.
  Looking at it now: it covers the Deployment, Service and autoscaling half of
  this chart. It does not have the deployment-to-job inheritance, or the hook
  prerequisite copies the `helm` CLI path needs (ADR 0002, 0007, 0010, 0011).
  It also lacks `fail` messages that name the values path, and a closed
  schema. Those are what a values author relies on. It also ships
  `rawResources`, the field this ADR rules out. Moving to it now would
  cost more than it saves.

## Consequences

- A request for an object outside the criterion is answered with this ADR, not
  with a new values field.
- Since the schema is what a values author reads, every property needs a
  `description`. The CHANGELOG uses the same idea: a removed key is first
  deprecated with a warning, and then fails with a message that names its
  replacement. Both are tracked as issues (#203, #205). A guide written for
  values authors is tracked in #204.
