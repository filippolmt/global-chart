# Domain docs

Single context: `GLOSSARY.md` and `docs/adr/` at the repository root.

## Before exploring, read these

- **`GLOSSARY.md`**: the domain terms. Write a new or sharpened term here, in its format (definition, then an `_Avoid_` line).
- **`docs/adr/`**: the ADRs that touch the area you are about to work in. They are numbered `NNNN-<slug>.md` and linked from `CHANGELOG.md`.

## Use the glossary's vocabulary

When your output names a domain concept (an issue title, a refactor proposal, a hypothesis, a test name, a comment), use the term as `GLOSSARY.md` defines it, in italics, by its exact name. Its `_Avoid_` line lists the synonyms to leave out.

A concept you need that the glossary lacks is a signal: either you are inventing language the project does not use (reconsider), or there is a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

When your output contradicts an existing ADR, say so explicitly:

> _Contradicts ADR 0011 (hook prerequisite ServiceAccount copy under its own name), but worth reopening because…_
