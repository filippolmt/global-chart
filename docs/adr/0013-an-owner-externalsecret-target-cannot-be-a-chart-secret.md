---
status: accepted
---

# An `Owner` ExternalSecret target cannot be a Secret the chart renders

`externalSecrets.<key>` and `deployments.<key>.secret` both default to
`<fullname>-<key>` (issue #153). Naming an ExternalSecret after its deployment,
the natural choice, renders a Secret owned by Helm and an ExternalSecret whose
`creationPolicy: Owner` target has the same name. Helm and ESO then overwrite
each other's `data`, and deleting the ExternalSecret garbage-collects the Helm
Secret. `validateNameCollisions` registered only the hook copy's target
(`<target>-hook`) among the chart's Secret names, never the real one.

## Decisions

**The `Owner` target joins the chart's Secret names**, so a clash with a
deployment Secret, its `-hook-secret` prerequisite copy or any other chart
Secret is a render `fail`.

**`Merge` and `None` stay allowed.** `Merge` adds keys to a Secret that already
exists, and Helm's three-way patch touches only the keys in its own manifest, so
writing into a chart Secret with `Merge` is a usable pattern rather than a
fight. `None` writes nothing. Rejecting them would forbid a working
configuration to prevent no failure.

The `Merge` premise holds, checked against the sources. Helm 3 upgrades with a
three-way strategic merge patch whose deletions come only from the old manifest
against the new one, so a `data` key in neither manifest — one ESO added — is
never removed. Helm 4 defaults to server-side apply, which prunes only the
fields Helm's own field manager dropped. A fight remains only on a key both
sides write, which is a values mistake the render cannot see; `helm upgrade
--force` (a replace) also drops ESO's keys until its next refresh.

`Orphan` and `CreateOrMerge` are left as they are, as `Merge` and `None` were
before this change. `CreateOrMerge` keeps existing keys like `Merge`. `Orphan`
clears `data` like `Owner` but sets no ownerReference, so it fights Helm without
the garbage collection; joining it to `Owner` is a separate decision (issue
#161), and the
schema does not constrain `creationPolicy` today.

## Consequences

- A release with an ExternalSecret named after a deployment that also declares
  `secret:` now fails to render. The migration guide gives the cure: rename
  `target.name`, or drop `secret:` from the deployment.
