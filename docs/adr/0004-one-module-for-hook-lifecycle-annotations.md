---
status: accepted
---

# One module for hook lifecycle annotations

The three `helm.sh/hook*` annotations are emitted from seven sites in `hook.yaml`,
with four separate derivations of the effective hook weight and three different
delete-policy literals. (An eighth site, `templates/tests/test-connection.yaml`,
is deliberately out of scope: the `helm test` hook has no weight and no command,
and routing it through a helper that always emits `helm.sh/hook-weight` would add
an annotation it does not have today.) The ordering invariant `prereq w-7 < SA w-5 < Job w` exists
only as a comment repeated three times, plus CLAUDE.md and ADR 0002 — and ADR 0002
had to add the fourth weight calculation (`preInstallMinWeight`) because there was
no module to extend. We centralise the whole hook lifecycle — weight, offset,
delete policy — in `hookAnnotations`, in a new `_hook-helpers.tpl`.

The interface is `hookAnnotations(hookType · role · command | weight)`. `role` is one
of four values and is **orthogonal to scope**: a hook resource is a `job`, a `sa`
(chart-created ServiceAccount for a single hook), a `prereq` (the ConfigMap/Secret
copies) or a `pre-install-sa` (the ServiceAccount copy of ADR 0002). The role
selects a row of a table — weight offset, delete-policy default, and whether the
resource belongs to one hook — and nothing else.

The last argument says where the weight comes from, and that is also what decides
whether an explicit `deletePolicy` applies. The roles a hook owns (`job`, `sa`) are
called with that hook's own `command`, so its `deletePolicy` reaches them. The
plumbing roles are called with a `weight` and no command, because their weight is a
minimum across several hooks rather than one hook's own — and handing one a command
is a template error, so the fixed-policy ruling below is enforced by the interface
rather than left to convention. An unknown role fails too: without that guard it
takes offset 0 and renders a null delete policy, an invalid annotation the API
server rejects far from its cause. The minima come from `minHookWeight(hooks)`, and
the default-10 rule itself from `effectiveHookWeight(command)`, so that rule exists
once for all of them.

Derived weights are still never floored at 0, for the reason ADR 0002 gives.
Weights are coerced with `int` in every role, including the Job — today the Job
emits the raw value while its own ServiceAccount coerces it, so a non-canonical
string weight already renders two inconsistent numbers for the same hook.

The helper takes no `root`: it reads nothing from it. Deployment-level hook labels
are a separate duplication, folded into the existing `hookLabelsWithComponent` in
`_helpers.tpl`: it now takes a dict and appends the component from an optional
`deploymentName`, so both hook scopes call one helper the same way.

Common and user-supplied annotations stay at the call sites: they are not hook
lifecycle, and their position around the three `helm.sh/…` keys differs by role.
They are merged into a single map by `renderAnnotations`, and the three
`helm.sh/hook*` deliberately stay out of that merge: they are the chart's own, and
letting `global.commonAnnotations` overwrite one would silently change the hook
ordering at runtime. `hookAnnotations` is rendered after the merged map, so the
chart wins whatever the values say.

This does not reopen ADR 0001. No `scope` parameter is introduced and PART 1 and
PART 2 stay separate; `role` is a different axis, and root-level and
deployment-level hooks were already emitting byte-identical lifecycle annotations
for the roles they share. This is the same "extract only the truly-shared logic"
clause that ADR 0001 chose and that `jobServiceAccount` already applies.

## Considered options

- **Let the prereq copies and the pre-install SA copy honour an explicit
  `deletePolicy`**, as CLAUDE.md pattern 8 currently claims they do — rejected.
  The prereq ConfigMap/Secret are per-deployment and shared by *every* hook of that
  deployment, so "the explicit delete policy" has no owner: two sibling hooks with
  different policies make the rule undecidable, and no precedence between siblings
  has ever been defined. The pre-install ServiceAccount copy cannot honour one
  either — ADR 0002 rejects `before-hook-creation` on it as destructive mid-upgrade.
  Pattern 8 is wrong about the plumbing resources and is corrected rather than
  implemented: hook **Jobs** and chart-created per-hook **ServiceAccounts** honour an
  explicit policy; plumbing resources have a fixed policy per role.
- **Leave the ADR 0002 copy out and cover three roles** — rejected. It is the
  fourth weight calculation and the evidence that the invariant had no home;
  excluding it guarantees a fifth one the next time a role is added.
- **Have callers resolve weight and policy, leaving the helper a pure offset
  table** — rejected. `int (ternary $command.weight 10 (hasKey $command "weight"))`
  would stay duplicated at four sites, which is the duplication this ADR exists to
  remove.
- **Absorb `renderAnnotations` and produce a complete `annotations:` block** —
  rejected. It adds a parameter and a role-conditional ordering inside the helper to
  save one line per call site.

## Consequences

- Rendered output is unchanged except for weights written as non-canonical strings,
  which now render consistently across a hook and its ServiceAccount instead of
  diverging: `weight: "007"` rendered `"007"` on the Job and `"2"` on its SA, and
  renders `"7"` and `"2"` now.
- The schema still accepts `["string", "integer"]`, but a string must now look like
  an integer (`^-?[0-9]+$`). Coercing consistently made the remaining hole worse,
  not better: a string `int` cannot parse becomes 0, so `weight: " 5"` used to mean
  0 on every resource but the Job and would now mean 0 on all of them — silently, in
  the one field whose whole purpose is relative order. It is rejected at lint time
  instead. `"007"`, `"-5"` and every canonical form still validate.
- The 24 `hook-weight` and 13 `hook-delete-policy` assertions in `hook_test.yaml`
  are **kept**, not collapsed: they pin the rendered output — which weight lands on
  which resource under which `helm.sh/hook` — not the helper. A table test for the
  module is added alongside them. It asserts what renders: that a hook's explicit
  `deletePolicy` lands on its Job and its ServiceAccount and never on the plumbing
  copies beside them. There is no flag inside the helper for it to pin.
- `make e2e` is mandatory for this change: weights, ordering and delete policies are
  runtime behaviour that `helm-unittest` cannot observe. The existing scenario's
  `weight: "-5"` hook already covers the never-floor-at-0 rule; no new scenario is
  needed.
- CLAUDE.md pattern 6 points at the helper instead of restating the formula, and
  pattern 8 is corrected as described above.
- Adding a fifth hook role becomes one row of the table.
