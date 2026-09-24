---
status: accepted
---

# The fullname constraint follows what the release renders

`global-chart.fullname` heads almost every name the chart renders, and nothing
constrained what went into it (issue #120). Helm accepts a dotted release name
(`my.app`), `nameOverride` and `fullnameOverride` were bare strings, and
`trunc 63 | trimSuffix "-"` left a `.` or `_` where the cut landed. The results
rendered, passed `helm lint`, and were rejected by the API server.

Most names the fullname heads are DNS-1123 subdomains. Two are stricter: a
container name is a DNS-1123 **label** (no dot), and a Service name is a
DNS-1035 label (no dot, and a letter first).

## Decisions

**The overrides are DNS-1123 subdomains in the schema, not labels.** A subdomain
is the loosest name they reach, and the schema cannot see the release name,
which joins them in the fullname. Holding the overrides to a label would still
let `my.app` through the release name, and would reject a dotted override on a
release where no label is ever built from it. The schema alone, though, leaves
the reported bug in place: `my.app` still reaches a container name. Hence the
render-time check below.

**A render-time `fail` covers the labels, and only for releases that build
one.** `validateFullname` fails on a dot when an enabled Deployment or a
root-level hook names a container after the fullname, and on a leading digit
when an enabled deployment's Service is named after it. A cronjob-only release
names its CronJobs and ServiceAccounts (subdomains) after the fullname and its
container after the job key, so `helm template my.app … --set cronJobs.…`
renders valid names today — a label rule everywhere would break it, for no
invalid name prevented.

**Not a container name decoupled from the fullname.** It would remove the dot
problem for containers at the root, but it renames the container of every
Deployment, which is breaking for anyone who selects on it. Deferred to the next
major.

**Uppercase is not checked at render time.** Helm rejects it in a release name
and the schema rejects it in the overrides. The check also stays clear of
helm-unittest's `RELEASE-NAME` default, which no real release can carry.

**One truncation helper, `truncName`, trims `[-._]+$`.** `trimSuffix "-" |
trimSuffix "."` turns `a-.` into `a-`, still invalid. The `_` is there for the
`helm.sh/chart` label value, where `+` becomes `_`.
