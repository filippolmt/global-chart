---
status: accepted
---

# A job's pod-level `automountServiceAccountToken` follows the inheritance chain

`jobPodSpec` never rendered the pod-level `automountServiceAccountToken` (issue
#154). A job's own value reached only a ServiceAccount the job creates itself,
so in the common case — a job running as its deployment's SA or as the hook
copy `<sa>-hook` — the token was mounted anyway, and a Deployment's pod-level
`false` did not reach the cronjobs running as the same SA. The schema accepted
the hardening field and the template ignored it.

## Decisions

**The pod field follows the usual chain:** the job's own value, then — in the
deployment scope only — the deployment's pod-level value, else the field is
omitted and the ServiceAccount decides. A root-scope job reads only its own
value. An explicit `true` on the job beats the deployment's `false`.

**The deployment's `false` does not reach an SA the job creates.** The pod-level
field already closes the token, and Kubernetes gives it precedence over the SA's
`automountServiceAccountToken`. Carrying the value into the SA as well would mix
two levels to change nothing.

**The job's field keeps both roles:** it sets the pod field and stays the
fallback for the automount of the SA the job creates. Dropping the second role
would change an SA's behaviour for no gain, and the two never contradict each
other, because the pod field wins.

## Consequences

- Jobs of a deployment that already sets pod-level `false` lose the token. A
  hook or cronjob that calls the Kubernetes API sees a missing token or a `403`.
  The migration guide gives the cure: `automountServiceAccountToken: true` on
  the job.
