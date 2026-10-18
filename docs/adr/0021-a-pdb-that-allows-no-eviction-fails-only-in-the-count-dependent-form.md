---
status: accepted
---

# A PDB that allows no eviction fails only in the form that depends on the count

A PodDisruptionBudget whose `minAvailable` reaches every pod of its workload
allows no voluntary eviction. `kubectl drain` and cluster-autoscaler scale-down
then never finish on the node, and Kubernetes accepts the manifest without a
word (issue #216). The typical case is a PDB shared across environments
together with `replicaCount: 1` in dev or staging.

**The render fails, but only when the PDB's effect depends on the count.**
`minAvailable` as an integer ≥ N fails, and so does a percentage below 100%
that rounds up to N. Percentages round up as the disruption controller does
(`GetScaledValueFromIntOrPercent(…, true)`). `maxUnavailable: 0`, `"0%"` and
`minAvailable: "100%"` block evictions at any count, so whoever writes them
means it: they render. They are also the way to block drains on purpose, so
no opt-out field is needed.

**N is the replica owner's floor** (ADR 0003, ADR 0012), resolved in one
helper, `replicaFloor`, which also decides whether `deployment.yaml` (now `workload.yaml`) emits
`spec.replicas`:

- `replicaCount`, or 2 when absent;
- `autoscaling.minReplicas`;
- `keda.minReplicaCount`, whose default is 0.

The floor is where an autoscaled workload idles, which is when the cluster
autoscaler wants its node back. A floor of 0 renders, because a workload with
no pods blocks nothing. This leaves one known gap: a KEDA workload that
scales from 0 to 1 pod blocks while it runs that one pod, and the chart does
not catch it.

## Considered options

- **A warning in NOTES.** `helm template` and Argo CD never show NOTES, so
  about half of the installs would never see it (see the Helm-floor warning in
  `NOTES.txt`).
- **A fail on every form, with an opt-out field.** It needs a new schema field
  and a closure fixture just to express what `maxUnavailable: 0` already says.
- **Only a single replica, as the issue title says.** `replicaCount: 3` with
  `minAvailable: 3` is the same bug with the same arithmetic.
