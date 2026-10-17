---
status: accepted
---

# A workload's kind is a field of its `deployments` entry

Issue #211 asked for chart-rendered PersistentVolumeClaims mounted by
single-replica Deployments, for stateful dependencies such as Elasticsearch,
kvrocks and NATS JetStream. That design would have rebuilt by hand what a
StatefulSet already guarantees:

- a rollout that does not deadlock on a RWO volume;
- one claim per pod;
- at most one pod per identity when a node is lost;
- claims that Helm and Argo CD do not delete;
- a stable network identity.

It would also have carried its own rules on `strategy`, on replica owners and on
retention annotations. The chart renders StatefulSets instead. ADR 0019 already
admits them, since their pod spec goes through the same helpers. The values are
designed for a DaemonSet as well, which comes later.

**`deployments.<name>.kind: Deployment | StatefulSet`, default `Deployment`.**
The pod spec, the labels, the checksums, Reloader, the PDB, the NetworkPolicy
and the workload-scope jobs read only the values, never the kind. So one entry
with a kind keeps every one of them as it is. The map keeps the name
`deployments`: `GLOSSARY.md` defines its entries as *workloads*.

## Decisions

**Kind-specific fields exclude each other in the schema.** `strategy` and
`progressDeadlineSeconds` are rejected on a StatefulSet. `updateStrategy`,
`podManagementPolicy`, `volumeClaimTemplates` and
`persistentVolumeClaimRetentionPolicy` are rejected on a Deployment. The
rejection is an `if/then` on `kind`, with a backstop guard in the template.

**A StatefulSet name longer than 52 characters fails the render; it is not
truncated.** The StatefulSet controller labels every pod
`controller-revision-hash: <name>-<hash>`. The hash is a decimal `uint32` of
up to 10 characters (`pkg/controller/history/controller_history.go`), and a
label value has at most 63. Between 53 and 62 characters, whether a pod can be
created depends on the hash, so the failure is intermittent. Truncating only
the StatefulSet would split its name from its Service, ServiceAccount and HPA,
which `validateNameCollisions` treats as one name.

**Every StatefulSet gets a headless Service, `<fullname>-headless`,** even when
`service.enabled` is `false`. `serviceName` must point to an existing Service
for the pods' DNS names to resolve. It sets `publishNotReadyAddresses` so that
peers find each other before they are ready. Routes and the Ingress keep
pointing to the normal Service.

**Claims are retained by Kubernetes, not by annotations.**
`persistentVolumeClaimRetentionPolicy` defaults to `Retain` on deletion and on
scale-down. Claims created from `volumeClaimTemplates` are not in the manifest,
so neither `helm uninstall` nor an Argo CD prune deletes them. The policy is
beta and on by default from Kubernetes 1.27, and a cluster that does not know
the field drops it without a word. So the chart's `kubeVersion` floor rises to
`>=1.27.0-0`.

**A `volumeClaimTemplates` entry that no `volumeMounts` item mounts fails the
render.**

**HPA and KEDA work on a StatefulSet** under the same one-replica-owner rule
(ADR 0003, ADR 0012).

**Workload-scope jobs inherit from a StatefulSet as they do from a
Deployment.** They do not inherit its claims, because a claim belongs to one
pod.

## Considered Options

- **Deployment + a root `persistentVolumeClaims` map** (the original proposal
  in #211). Rejected for the reasons above.
- **Parallel root maps, `statefulSets.<name>` and `daemonSets.<name>`.**
  Rejected: every helper that iterates `deployments` would iterate three maps,
  `deployments.es` and `statefulSets.es` would collide on one fullname, and
  route backends and hook references would need a type of their own.
- **Rename the map to `workloads.<name>.kind`.** Rejected: a major release for
  every existing values file, with no functional gain.

## Consequences

- Changing `kind` on an installed entry replaces the workload. The Deployment
  is deleted and the StatefulSet created, and for a moment their pods share a
  selector. The README lists it under *Decide before the first install*.
- `volumeClaimTemplates` is immutable on a StatefulSet. Changing a size or a
  storage class means `kubectl delete sts --cascade=orphan` and a new sync.
  The README documents the procedure.
- The `kubeVersion` floor is a breaking change, recorded in the CHANGELOG.
- Under Argo CD label tracking (`application.resourceTrackingMethod: label`),
  a claim that inherits `app.kubernetes.io/instance` from its template is
  ambiguous to Argo CD. Its docs warn that generated resources carrying the
  label confuse it about ownership. Whether a prune would then delete the claim
  is not verified. Annotation tracking is the default and avoids the question.
  `make e2e-argocd` asserts that the claims survive the Application's deletion.
