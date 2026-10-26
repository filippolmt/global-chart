# Delivery and orchestration

## Delegation

Choose agent names from the current harness's available-agent list, not from
names remembered from another harness. Inspect changed files and verification
results after delegation: a sub-agent's completion report is evidence to check,
not a replacement for checking the final diff.

## Commit boundary

Check `git status --short`, then stage the intended paths explicitly. Run
`git diff --cached --check` and inspect `git diff --cached --stat` before the
commit: `git diff --check` alone excludes untracked new files. Preserve unrelated
working-tree and staged changes.

## Completion report

Distinguish local verification from CI. When reporting CI success, verify the
run's `headSha` matches the pushed commit; report pending or unchecked CI as such.
CI log retrieval and monitoring: `docs/agents/issue-tracker.md`, *CI diagnostics*.
