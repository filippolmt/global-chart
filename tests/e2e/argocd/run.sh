#!/bin/sh
# `make e2e-argocd`: the hook-prerequisite copies under a real Argo CD sync
# (issues #149, #164). Called by the Makefile with KUBECONFIG pinned to the kind
# cluster, Argo CD and ESO already installed. See tests/e2e/README.md.
set -eu
# The kind cluster only, as for `make e2e`: this script deletes namespaces and
# overwrites the "default" AppProject, which on a real Argo CD is not a test.
case "${KUBECONFIG:-}" in
*/.bin/kind-kubeconfig) ;;
*) echo "refusing to run: KUBECONFIG must be the e2e kind kubeconfig; use make e2e-argocd"; exit 1 ;;
esac
here=$(dirname "$0")
chart=$1
argo=${ARGOCD_NAMESPACE:?}
ns=global-chart-argocd
fn=argo-global-chart
work=$(mktemp -d)
trap 'kubectl -n $argo delete application e2e --ignore-not-found >/dev/null 2>&1 || true; kubectl delete ns $ns --wait=false >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

fail() {
	echo "FAIL: $*"
	kubectl -n $argo get application e2e -o jsonpath='{.status.operationState.message}{"\n"}{range .status.operationState.syncResult.resources[*]}    {.kind}/{.name} {.hookPhase} {.message}{"\n"}{end}' 2>/dev/null || true
	exit 1
}

# Starts one sync operation and waits for it to end with the phase in $1. The
# controller removes .operation when the operation ends, retries included.
sync() {
	kubectl -n $argo patch application e2e --type merge \
		-p '{"operation":{"initiatedBy":{"username":"e2e"},"sync":{"revision":"'"$version"'"}}}' >/dev/null
	i=0
	while [ -n "$(kubectl -n $argo get application e2e -o jsonpath='{.operation}')" ]; do
		i=$((i + 1)); [ $i -le 300 ] || fail "sync still running after 300s"
		sleep 1
	done
	phase=$(kubectl -n $argo get application e2e -o jsonpath='{.status.operationState.phase}')
	[ "$phase" = "$1" ] || fail "sync ended $phase, expected $1"
}

copies_gone() {
	kubectl -n $ns wait --for=delete sa/$fn-app-hook configmap/$fn-app-hook-config \
		externalsecret/$fn-e2e-env-hook secret/$fn-e2e-env-hook --timeout=60s >/dev/null 2>&1 \
		|| { kubectl -n $ns get sa,cm,secret,externalsecret; fail "hook copies survived $1"; }
}

sa_uid() { kubectl -n $ns get sa $fn-app -o jsonpath='{.metadata.uid}'; }

echo "==> Clearing any Application or namespace left by a previous run..."
kubectl -n $argo delete application e2e --ignore-not-found --timeout=60s >/dev/null
kubectl delete ns $ns --ignore-not-found --timeout=180s >/dev/null

# A unique version and repository path per run: the repo-server caches a chart
# by version and a repository's index by URL, so a rerun would otherwise sync
# the previous run's chart, or look for this one in the previous index.
stamp=$(date +%s)
version=$(helm show chart "$chart" | awk '/^version:/ {print $2}')-e2e.$stamp
repo=http://chart-repo.$argo.svc/$stamp
echo "==> Serving global-chart $version from an in-cluster Helm repository..."
helm package "$chart" --version "$version" -d "$work" >/dev/null
helm repo index "$work" --url $repo
kubectl -n $argo create configmap chart-repo --from-file="$work" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Recreated, not rolled: a pod of the previous run still behind the Service
# would answer 404 for this run's path.
kubectl -n $argo delete deploy/chart-repo --ignore-not-found --cascade=foreground --timeout=60s >/dev/null
sed "s#CHART_STAMP#$stamp#g" "$here/chart-repo.yaml" | kubectl -n $argo apply -f - >/dev/null
kubectl -n $argo rollout status deploy/chart-repo --timeout=120s >/dev/null
# Created here, not by CreateNamespace=true: an operation started by patching
# .operation carries no syncOptions of its own, and the spec's are not read.
kubectl create ns $ns >/dev/null
sed "s#CHART_VERSION#$version#; s#CHART_REPO#$repo#" "$here/application.yaml" | kubectl -n $argo apply -f - >/dev/null

echo "==> First sync..."
sync Succeeded
[ "$(kubectl -n $ns get job $fn-app-pre-install-migration -o jsonpath='{.status.succeeded}')" = "1" ] \
	|| fail "the PreSync hook did not succeed"
[ "$(kubectl -n $ns get job $fn-app-pre-install-migration -o jsonpath='{.spec.template.spec.serviceAccountName}')" = "$fn-app-hook" ] \
	|| fail "the PreSync hook did not run as the SA copy <sa>-hook (ADR 0011)"
copies_gone "a successful PreSync"
echo "    PreSync hook ran as <sa>-hook and read the ExternalSecret copy; copies gone"
uid=$(sa_uid)

echo "==> Second sync (pre-install runs again under Argo CD)..."
sync Succeeded
[ "$uid" = "$(sa_uid)" ] || fail "the real SA was recreated by the second sync (issue #141)"
copies_gone "the second PreSync"
echo "    real SA kept its UID, copies gone"

echo "==> Sync with a failing PreSync hook after the copies..."
kubectl -n $argo patch application e2e --type merge --patch-file "$here/break.yaml" >/dev/null
sync Failed
copies_gone "a failed PreSync (hook-failed, ADR 0015)"
echo "    failed sync deleted its copies"

echo "==> Retry with the failure fixed..."
kubectl -n $argo patch application e2e --type merge --patch-file "$here/unbreak.yaml" >/dev/null
sync Succeeded
[ "$uid" = "$(sa_uid)" ] || fail "the real SA was recreated by the retry"
copies_gone "the retry"
echo "    the next sync passed"
echo "==> e2e-argocd passed"
