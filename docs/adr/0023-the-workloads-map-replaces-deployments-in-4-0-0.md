---
status: accepted
---

# The `workloads` map replaces `deployments` in 4.0.0, with no deprecation minor

Since issue #211 an entry of the root map can render a StatefulSet, and issue
#215 adds a DaemonSet. The values still named every entry a deployment:
`deployments.db.kind: StatefulSet`, `fromDeployment: db`. The key said
something false about the entry it held. ADR 0020 rejected renaming the map
because a rename costs a major release. That cost no longer stands alone:
4.0.0 is already a major (issue #230, the `kubeVersion` floor, issue #216).

**The values keys say *workload* from 4.0.0 on (issue #221).**

| Removed | Replacement |
|---------|-------------|
| `deployments.<name>` | `workloads.<name>` |
| `fromDeployment` (root-scope hooks and cronJobs) | `fromWorkload` |
| `inheritDeploymentConfigMap`, `inheritDeploymentSecret`, `inheritDeploymentEnvFromConfigMaps`, `inheritDeploymentEnvFromSecrets` (workload-scope hooks and cronJobs) | `inheritWorkload…`, same suffix |
| the backend key `deployment` (`ingress.hosts[]`, the `httpRoute` / `httpRoutes` and L4 route `backendRefs`) | `workload` |

Each removed key fails as ADR 0022 requires: it stays declared in the schema
with no constraint, and `rejectRemovedKeys` fails with
`<values path>: removed in 4.0.0, use <replacement>`. The `deployments`
failure also links the *Migration guide* in `CHANGELOG.md`, since the other
renames come with it. Helm renders `validate.yaml` before any other template, so
an old values file meets that failure first (checked on Helm 4.3.1). The
other keys fail where they are read, like the volume keys of issue #230: on
a surface that renders nothing (`enabled: false` on the Ingress, an
HTTPRoute or a workload) the old key is not read, and it fails once the
surface is enabled. The
failures, the declarations and their fixtures go in 5.0.0.

**There is no deprecation minor.** This is an exception to phase 1 of the
deprecation rule in `CODING_STANDARDS.md`. `main` already carries breaking
changes, so the next release is 4.0.0, and no 3.x minor can ship from it.
Accepting both forms for a whole major has a cost too: every helper that
reads the map, 36 sites in the templates today, would merge two
maps and check that a name is not set in both. The migration is a rename, and the
first failed render names the key to rename.

Nothing in the cluster changes. The resource names (`{release}-{chart}-{name}`)
and the selector label `app.kubernetes.io/component: {name}` do not depend on
the map's name, so no workload is recreated. The helper names
(`deploymentFullname`, `deploymentValuesPath`, …) and the schema `$defs` names
(`deployment`, `deploymentName`, `deploymentJobSpec`, …) stay: they are not
part of the values API.

## Considered Options

- **Deprecate in 4.0.0, remove in 5.0.0.** This follows the rule. Rejected:
  the two forms would live side by side for a whole major, with a conflict
  check at every site that reads the map, and the false key would stay
  documented for another major.
- **A deprecation-only 3.4.0 from a branch cut at the 3.3.0 tag.** Rejected:
  chart-releaser publishes from `main` only, and a release branch is a process
  the repository does not have.
- **Keep `deployments` (ADR 0020 as written).** Rejected: the DaemonSet makes
  the key wrong for two kinds out of three.

## Consequences

- Every values file migrates at 4.0.0 and gets no warning release first. The
  CHANGELOG lists the rename under *Removed* as Breaking, and the 3.x
  migration guide has a row for each key.
- ADR 0020's rejection of the rename is superseded; the rest of ADR 0020 stands.
- The text rule of `CODING_STANDARDS.md` (*Text names a kind only where it
  holds for that kind alone*) now applies to the values keys too.
