# Issue tracker: GitHub

Issues and specs live as GitHub issues on `filippolmt/global-chart`, through the `gh` CLI (`gh` infers the repo inside a clone).

## Conventions

- **Create**: `gh issue create --title "..." --body-file <file>`. Issues go in this repository only.
- **Read**: `gh issue view <number> --comments`. A "Decisions" comment from the owner amends the body: read the body as amended.
- **List**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`, with `--label` / `--state` filters.
- **Comment**: `gh issue comment <number> --body "..."`
- **Labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`
- **The spec of a branch** is the `#<n>` in its commit messages.
- **Pull requests**: `gh pr view|create|edit`; the PR body names the issue it closes (`Closes #<n>`). Issues and PRs share one number space: resolve a bare `#42` with `gh pr view 42`, falling back to `gh issue view 42`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.
