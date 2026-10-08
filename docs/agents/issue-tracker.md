# Issue tracker

GitHub Issues on `filippolmt/global-chart`, through the `gh` CLI (authenticated
on the developer's machine).

- Read an issue with its discussion: `gh issue view <n> --comments`. A
  "Decisions" comment from the owner amends the body: read the body as amended.
- Find the spec of a branch: the `#<n>` in its commit messages.
- Create: `gh issue create --title … --body-file …`. Issues go in this
  repository only.
- Pull requests: `gh pr view|create|edit`; the PR body names the issue it closes
  (`Closes #<n>`).
