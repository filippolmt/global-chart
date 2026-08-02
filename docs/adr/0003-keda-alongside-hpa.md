---
status: accepted
---

# KEDA sits alongside the HPA, and an autoscaler owns `spec.replicas`

The chart could only scale on CPU and memory: `hpa.yaml` renders an
`autoscaling/v2` HorizontalPodAutoscaler with `Resource` metrics and nothing
else. Event-driven workloads — queue consumers, burst workers — had no home.
Adding KEDA raised two decisions worth recording.

## `deployments.<name>.keda` is a sibling of `autoscaling`, not a mode of it

`$defs.autoscaling` is shaped by the HPA: `minReplicas`, `maxReplicas`,
`targetCPUUtilizationPercentage`, `behavior`. KEDA's ScaledObject uses
`minReplicaCount`, `maxReplicaCount`, `pollingInterval`, `cooldownPeriod`,
`triggers`, `advanced.horizontalPodAutoscalerConfig.behavior`. The two vocabularies
barely overlap.

`keda` therefore gets its own key and its own `$defs.kedaScaledObject`, using
KEDA's native field names verbatim — the upstream KEDA documentation applies
directly to the values a user writes.

The two are mutually exclusive per deployment, enforced by
`global-chart.validateAutoscalingConflict` (`_validate-helpers.tpl`), because KEDA
creates and owns its own HorizontalPodAutoscaler for every ScaledObject — the
*derived HPA*. Two HPAs on one Deployment means two controllers writing
`spec.replicas`.

### Considered options

- **`autoscaling.mode: hpa|keda` with shared neutral field names** — rejected.
  It makes `autoscaling.enabled` ambiguous, leaves half the block inert in either
  mode, translates field names behind the user's back (so the KEDA docs no longer
  match the values), and is a breaking change to an existing public block.
- **`autoscaling.keda` nested** — rejected for the same ambiguity on
  `autoscaling.enabled`, with no gain over a sibling key.
- **A sibling `keda` key** — chosen.

## The Deployment stops emitting `spec.replicas` when an autoscaler owns it

`deployment.yaml` already suppressed `replicas` under `autoscaling.enabled`. The
guard is now expressed over *any* autoscaler rather than the HPA specifically, so
KEDA gets the same treatment: emitting `spec.replicas` would make every
`helm upgrade` overwrite the live replica count, and with `minReplicaCount: 0` it
would wake a workload that was deliberately scaled to zero.

The rule is worth stating as a rule, not as two coincidences: whoever owns
`spec.replicas` is the only writer, and the chart is not it. Nothing changes for
existing `autoscaling` users.

### Considered options

- **Guard on `autoscaling.enabled` only, and let KEDA users live with the reset**
  — rejected. It makes KEDA scale-to-zero unusable with this chart.
- **Guard on either autoscaler** — chosen.

## Consequences

- `deployments.<name>.autoscaling` and `deployments.<name>.keda` both exist;
  neither is deprecated. Enabling both on one deployment is a template `fail`.
- Deployments under either autoscaler have no `spec.replicas` in the rendered
  manifest. `replicaCount` is silently inert there — the schema cannot express
  the dependency, so `deployment_test.yaml` locks the behaviour for both.
- The KEDA templates require the `keda.sh/v1alpha1` CRDs. Offline rendering
  needs `--api-versions keda.sh/v1alpha1`; see `_keda-helpers.tpl` and the
  `HELM_API_VERSIONS` variable in the Makefile.
- `make e2e` installs the KEDA operator into its kind cluster, so the whole
  chain — trigger, derived HPA, scaled Deployment — is exercised rather than
  assumed. It costs about a minute of image pulls per fresh cluster.
