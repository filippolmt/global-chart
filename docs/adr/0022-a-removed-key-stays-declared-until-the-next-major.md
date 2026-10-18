---
status: accepted
---

# A removed key stays declared until the next major, and only a template fail rejects it

Applications pin the chart and update it through Renovate, so removing a key
forces a migration in every repository, and a values author working from an
older README keeps writing the key. Only the error message can lead them to
what replaced it (issue #205).

**A removed key stays declared in the schema for one major, with no
constraint, and a template `fail` rejects it naming the replacement.** At the
next major the key goes for good. The phases and the message are in
`CODING_STANDARDS.md`.

Helm's schema validation has no custom error text, so a schema rejection
prints only the path. The removal of `mountedConfigFiles.files[].mountPath` in
3.0.0 (#115) is that case: `additional properties 'mountPath' not allowed`,
and nothing about `targetPath`. It is left as it is, since this rule would
retire its message at 4.0.0 anyway.

In a closed `$defs` (ADR 0006), the declaration is what lets the key past the
schema: the `$defs` accepts one more name, one that always fails. On an open
passthrough surface (ADR 0017), such as `volumes`, the key would reach the
template undeclared; it is declared all the same, because a template reads it
and every field a template reads is declared. Either way the declaration
carries no type or `enum`, which would reject a wrong value before the `fail`
could name the replacement.

The deprecation warning lives in `NOTES.txt`, which `helm template` and Argo
CD never show (ADR 0021 rejects NOTES for that reason). Here it is accepted:
the key still works while deprecated, so a missed warning costs nothing until
the major, and the major's `fail` reaches every install.

## Considered options

- **The schema rejects, a backstop guard names the replacement.** The guard
  fires only under `--skip-schema-validation`, so on every normal install the
  replacement is never printed.
- **The message encoded in the schema** (an `enum` whose one value is the
  text). The error wording depends on the validator, which changed between
  Helm 3 and Helm 4.
- **The `fail` kept forever.** Removed keys pile up in the schema and the
  templates; after one major, the migration guides carry the history.
