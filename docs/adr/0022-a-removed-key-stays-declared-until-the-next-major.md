---
status: accepted
---

# A removed key stays declared until the next major, and only a template fail rejects it

Applications pin the chart and update it through Renovate, so removing a key
forces a migration in every repository, and a values author working from an
older README keeps writing the key. Only the error message can lead them to
what replaced it (issue #205).

**A removed key stays declared in the schema for one major, and a template
`fail` rejects it:** `<values path>: removed in X.0.0, use <replacement>`,
with a `tests/bad-values/fail/` fixture asserting the message. At the next
major the declaration, the `fail` and the fixture go together, and the key is
unknown like any other. Before the removal the key is deprecated for at least
one minor release. The phases are in `CODING_STANDARDS.md`.

A closed `$defs` (ADR 0006) thus accepts one more name, one that always fails.
That is the price of the message: Helm's schema validation has no custom error
text, so a schema rejection prints only the path. The removal of
`mountedConfigFiles.files[].mountPath` in 3.0.0 (#115) is that case:
`additional properties 'mountPath' not allowed`, and nothing about
`targetPath`. It is left as it is, since this rule would retire its message at
4.0.0 anyway.

## Considered options

- **The schema rejects, a backstop guard names the replacement.** The guard
  fires only under `--skip-schema-validation`, so on every normal install the
  replacement is never printed.
- **The message encoded in the schema** (an `enum` whose one value is the
  text). The error wording depends on the validator, which changed between
  Helm 3 and Helm 4.
- **The `fail` kept forever.** Removed keys pile up in the schema and the
  templates; after one major, the migration guides carry the history.
