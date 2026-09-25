---
status: accepted
---

# Close the `$defs` that declare their properties

Ten of `values.schema.json`'s definitions accepted any key, and
`deployments.<name>` was one of them: `deployments.web.replicaz: 3` rendered a
Deployment without a word, and so did `cronJobs.demo.imagge`. The chart already
believed in closure — fifteen definitions carried `additionalProperties: false`,
and two `bad-values` fixtures say why in their own comments — it had just applied
it to half the file. The cost was live: `tests/hooks-sa-inheritance.yaml`
declared `additionalPorts` under `deployments.odoo` from `#37` onward. No
template reads that key, no other occurrence exists in the repo, and the
scenario passed lint, unit tests and `kubeconform` for as long. It meant
`service.extraPorts`.

A typo in a consumer's values was indistinguishable from a choice, and stayed
that way until the wrong behaviour showed up in the cluster, where nothing links
it back to the line that caused it.

## The criterion

**A `$defs` that declares its properties is closed. A `$defs` that exists to
pass a Kubernetes surface through stays open until we decide how much of that
surface to admit.**

Closed here: `networkPolicy`, `ingress`, `mountedConfigFiles`, `deployment`,
`externalSecret` (`additionalProperties: false`), and the four job composites
`cronJob`, `deploymentCronJob`, `hookJob`, `deploymentHookJob`
(`unevaluatedProperties: false`). Applying the criterion to the rest of the file
closed five more objects that are not `$defs` of their own but declare their
properties all the same, and whose templates read exactly those: the entries of
`ingress.tls`, of `ingress.hosts` and of a host's `paths`, a host's explicit
`service` reference, and the entries of `rbacs.roles`. That brings the file to
twenty-four closed `$defs` and four open ones.

Left open, and why: `probe` is `{"type": "object"}` with zero properties and
three `$ref`s pointing at it. Closing it means transcribing the Kubernetes probe
surface — `httpGet`, `tcpSocket`, `exec`, `grpc` and their fields — which is the
same "how much to admit" question that every other passthrough surface poses.
Those are one decision taken once, not a dozen taken a resource at a time, and
this ADR does not take it. Note that closure at one level leaves passthrough at
the level below: `networkPolicy` is closed, its `ingress` and `egress` arrays are
not; `resources` is closed, what it holds goes through `toYaml` verbatim.

The register, as of this ADR: `probe`; `volumes` (five places — the deployment
and the four job definitions); `networkPolicy.ingress` and `egress`;
`dataFrom[].sourceRef`; `resources.claims[]` and the `requests`/`limits` maps,
which stay open for extended resources like `nvidia.com/gpu`;
`rbacs.roles[].rules[]`, which are PolicyRules; `dnsConfig.options[]`;
`kedaTrigger.metadata` and `autoscaling.behavior` (*amended by issue #137:*
`kedaTrigger.metadata` values must be strings, the ScaledObject's
`map[string]string`, and the EnvVar lists close on `$defs/envVar`, whose three
fields leave nothing to decide); the
`kedaTriggerAuthentication` provider blocks; and the `filters[]` entries of an
`httpRouteRule` and of its `backendRefs`, which declare `type` as a constraint
but carry the Gateway API filter payload underneath.

`kedaScaledObject` has an `if`/`then` pair whose `if` declares `enabled`. That is
a conditional, not an object definition: closing it would stop it ever matching.
The coverage check skips it for the same reason it skips the `allOf` branches.

The five `allOf` branches — `jobCommon`, `cronJobSpec`, `hookJobSpec`,
`rootJobSpec`, `deploymentJobSpec` — **must stay open**, and this is the trap for
anyone who reads "close the open `$defs`" and counts them without looking at what
they are for. A branch of an `allOf` validates the whole object on its own:
`additionalProperties: false` on `cronJobSpec` rejects every key that
`jobCommon` contributes (`additional properties 'image' not allowed`), and vice
versa. The composition `#95` introduced — four job definitions built from five
shared branches, so a new job field is added once — rests on them being open.

## Draft 2019-09

`unevaluatedProperties` does not exist in Draft 7, and in Draft 7 the four
composites cannot be closed in any way that holds (see *Considered options*).
So `$schema` moves to `https://json-schema.org/draft/2019-09/schema`. The
migration is inert for everything already in the file: the schema uses no
construct whose meaning differs between the two drafts — no `dependencies`, no
array-form `items` — and `$defs` is already the 2019-09 spelling. The only
effect is the closure.

**The threshold, and the silent degradation.** Helm 3.12.3 through 3.18.0
*ignore* `unevaluatedProperties` without so much as a warning about the
`$schema`; 3.18.6 and 3.19.0 apply it. `Chart.yaml` declares
`kubeVersion: ">=1.19.0-0"` and no Helm constraint, so those consumers are
plausible. We name the threshold rather than avoid it: on older Helm the
consumer is exactly where they are today, never worse, and the five flat
definitions use `additionalProperties: false`, which holds in every draft — their
protection has no threshold at all.

## Proving it

Closure is only worth what the tests assert, and the tests asserted nothing here:
all five existing "unknown key" fixtures sat on definitions that were already
closed. `validate-bad-values` could not have noticed anyway — it asked that a
file be rejected by the schema *or* by a template `fail`, without distinguishing
which, so a schema hole covered by a `fail` was invisible by construction.

`tests/bad-values/` therefore splits into `schema/` and `fail/`, and the
directory *is* the declaration: a file in the wrong one fails immediately. The
`schema/` half asserts Helm's message `values don't meet the specifications of
the schema`, and the target errors out rather than going green if no file in
`schema/` produces it any more — a Helm that rewords it arrives only with a
deliberate bump of the `v4.3.0` pin, and that has to be visible. Each closed
definition gets a fixture of its own, one per file: a single file with many typos
would prove nothing, since one surviving closure is enough for it to be rejected
and the rest would go back to being invisible.

One fixture per definition is itself a rule nothing would enforce, so
`tests/bad-values/check-closure-coverage.py` reads the closed `$defs` out of the
schema, reads the `# covers: <defsName>` lines out of the fixtures, and fails on
either mismatch — a closure with no fixture, a marker naming nothing, a
definition covered twice. Closing a `$defs` without writing its fixture now fails
in `validate-bad-values` rather than at the next person's typo.

## Considered options

**Stay on Draft 7 and close the composites with `additionalProperties: false`.**
Rejected: measured, and it rejects everything. On the composite there are no
`properties` to evaluate, so every key is additional; on a branch, the branch
validates the whole object alone and each branch rejects the keys the others
contribute (`additional properties 'schedule', 'image' not allowed`).

**Stay on Draft 7 and use `propertyNames` with an `enum`.** Rejected: it works
in every draft, but it relists 42 names across the four definitions. A new job
field would go back to being added in five places, which is exactly the
duplication `#95` removed by composing the definitions from shared branches.

**Close everything, `probe` and the passthrough arrays included.** Rejected, for
now: it answers a question this ADR does not ask — how much of a Kubernetes
surface to admit — and answering it badly is worse than leaving the surface
open, because a schema that rejects a valid Kubernetes field is a chart the
consumer cannot use at all.

**Leave `validate-bad-values` as it was and just add fixtures.** Rejected: the
target asked only that a file be rejected, by the schema *or* by a template
`fail`. A fixture proving nothing looks exactly like a fixture proving
something, which is how these holes survived in the first place.

## Consequences

A values file with an undeclared key under `deployments.<name>`,
`cronJobs.<name>`, `hooks.<type>.<name>` or their deployment-level counterparts
now stops `helm install` and `helm upgrade` instead of rendering. That is the
point, and it is a breaking change for anyone whose values carry such a key
today — ours did, one, for the length of this ADR's backstory. The error names
the path, which is the whole win: the typo dies at the line that contains it.

On Helm below 3.18.6 the four job definitions behave exactly as before. The
consumer is never worse off than today, but "the schema now catches typos" is
only half true for them, which is why the CHANGELOG names the version.

`make validate-bad-values` needs Helm >= 3.18.6 to pass: the three job fixtures
go red below it, because the closure they assert is the one older Helm ignores.
CI pins `v4.3.0`, so this bites only a developer running an old Helm locally.

Closing an object does not close what hangs off it. `networkPolicy` is closed
and its `ingress`/`egress` arrays still take anything; the same holds for
`volumes` under the deployment and the four job definitions, and for
`dataFrom[].sourceRef`. Those four surfaces plus `probe` are one open question,
recorded here so it reads as a decision rather than the oversight it was.

Adding a field to a closed definition now means declaring it in the schema, or
the render stops. That was already the rule in `CLAUDE.md` ("every field a
template accesses must be declared in the schema"); until now nothing enforced
it.
