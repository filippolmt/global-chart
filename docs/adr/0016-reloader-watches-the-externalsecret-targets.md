---
status: accepted
---

# Reloader watches the ExternalSecret targets, by name

`checksum/external-secrets` (issue #174) hashes the ExternalSecret *spec*.
It misses three cases (issue #175):

- a new version of the value in the external store;
- the window in which the new pods start before ESO has rewritten the Secret;
- a `target.immutable` Secret.

Only a controller that watches the Secret itself can see the first two. The
chart cannot see the value. `deployments.<name>.reloader.externalSecrets: true`
therefore hands the job to Stakater Reloader. It renders
`secret.reloader.stakater.com/reload` on the Deployment's metadata, with the
target of every ExternalSecret the deployment references, env and mounted alike.

## Decisions

**Named targets, not `auto`.** `secret.reloader.stakater.com/auto` watches
every Secret the pod references, including the chart's own Secret. That Secret
already has `checksum/secret`, so every upgrade that changes it would add a
second rollout for nothing. Only `resolveExternalSecretRefs` knows the
generated target names, and they are not a public interface (ADR 0007). So the
list comes from the resolver, the same one that wires env and volumes, and never
from values. Reloader reads each entry as an anchored regex, so every name goes
through `regexQuoteMeta`.

**No `search`/`match`.** That route puts `match` on the Secret through
`target.template.metadata`. It would write into the ExternalSecret spec, change
its checksum, and mix the chart's template with the user's.

**The double rollout after a spec change is intended.** The checksum rolls the
pods, then Reloader rolls them again once ESO has rewritten the Secret. That
second rollout closes the rollout race.

**Union with the user's own key.** A user may also set
`secret.reloader.stakater.com/reload` in `annotations`, or in the common
annotations, to watch a Secret the chart only names. In that case the chart
merges the lists — the common one, the deployment's and the targets — with
duplicates removed, a target already listed bare included. "The user wins" would drop the
targets in silence, and "own wins over common" a shared list. A `fail` would force `target.name` on anyone who needs both.

**Active with nothing to watch is a render failure.** If the field is `true` and
the deployment references no `externalSecrets`, the chart fails the render, as
ADR 0012 does for autoscaling. The chart can see that this empty list is
empty. An immutable or `refreshPolicy: CreatedOnce` target stays in the list,
with docs only. A deployment can legitimately mix such a target with rotating
ones, and keeping it costs nothing.

**Reloader only, named in the field.** Wave watches the whole pod, like `auto`.
Kyverno has no standard key the chart could drive. An annotation for a missing
controller is inert, and no CRD exists to check for (see *Vendor-neutral*). So
the field name states what it depends on. Other controllers go through
`annotations`.

## Consequences

- The chart cannot choose Reloader's reload strategy, because that is a flag
  on Reloader's own Deployment. The README recommends `annotations` under
  Argo CD and Flux.
- Hooks and cronjobs get nothing: every run creates fresh pods.
