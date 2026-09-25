---
status: accepted
---

# `autoscaling.enabled` without an active metric is a render failure

`deployment.yaml` drops `spec.replicas` whenever `autoscaling.enabled` is true,
while `hpa.yaml` renders only when a CPU or memory target is positive (issue
#151). With `enabled: true` and no positive target neither side owns the replica
count: no HPA renders, and Kubernetes defaults the Deployment to **one** pod,
ignoring `replicaCount` and `minReplicas`. `helm lint` passes. `"80%"`, the
natural way to write a percentage, reads as 0 and hits the same path.

ADR 0003 states the rule this breaks: whoever owns `spec.replicas` is the only
writer. Here the Deployment gives up the count and nobody takes it.

## Decisions

**A `fail`, not a shared "HPA is effective" predicate.** Rendering the HPA
with an empty `metrics` list is no way out either: the API server defaults it
to CPU at 80%, another silent answer. A predicate read by both
templates would put `replicas: {{ replicaCount }}` back when no metric is active.
That makes `enabled: true` a setting that silently does nothing: the user's
mistake survives, only with three pods instead of one. `$defs.autoscaling` is
closed and admits no custom metrics, so `enabled: true` with no active target
has no legitimate use to preserve.

**One home for "a target is active".** The `float64 > 0` test lives in one helper
in `_validate-helpers.tpl`, read by `validateAutoscalingConflict` and by
`hpa.yaml` to build its `metrics` list. `hpa.yaml` then renders on
`autoscaling.enabled` and a non-empty result of that same helper: the validator
guarantees the metric, and the second test only keeps a render without
`validate.yaml` from emitting an empty `metrics` list. Two templates
deriving the same fact on their own is how issue #82 happened.

**The schema admits "off", not "on with a unit".** String targets take
`^(0|[1-9][0-9]*)?$`, so `""` (the `values.yaml` example) still means "this
metric is off" and `"80%"` is rejected. A leading zero is rejected too: a
string target prints unquoted, and `"010"` would reach the API server as the
YAML 1.1 octal 8. Integer targets take `minimum: 0`, not `1`: CPU 80 with
memory 0 is a valid configuration. The case "every target off" is the
template's to reject, not the schema's.

**The KEDA conflict fails first.** With `autoscaling` and `keda` both enabled and
no metric, the mutual-exclusion error is the more fundamental one, and fixing it
can make the other moot.

## Consequences

- A values file that rendered one silent pod now fails to render. The
  migration guide gives the cure: set a positive target, or disable autoscaling.
- The unit tests that encoded the bug ("should not render HPA when enabled but no
  metrics set", and the `deployment_test` replicas case without a metric) change
  to assert the failure or gain a metric.
