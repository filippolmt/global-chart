#!/usr/bin/env python3
"""PreToolUse hook: a kubectl or helm call that reaches a cluster names the e2e kind kubeconfig.

The default kube context of a developer machine can be production. The
Makefile pins every cluster target to .bin/kind-kubeconfig
(tests/e2e/README.md); a command typed by hand has no such pin, and one
dry run in the #254 session went to the default context, a production cluster.

Blocked (exit 2, the reason on stderr): a `kubectl` call, or a `helm` call with
a subcommand that talks to a cluster, in a command that does not name
.bin/kind-kubeconfig. Let through: `kubectl config|completion|version
--client`, `--help`, offline helm (template, lint, unittest, show, repo…), and
every make target.

shortcut: the kubeconfig is looked for anywhere in the command, not in the
call's own segment; parse the shell segments if a command ever mixes a pinned
call with an unpinned one.

Usage: kind-kubeconfig-only.py            (hook input as JSON on stdin)
       kind-kubeconfig-only.py --self-test
"""
import json
import re
import sys

KIND_KUBECONFIG = ".bin/kind-kubeconfig"
# In command position only: a line or segment start, after env assignments and
# a wrapper (sudo, env, xargs, watch, time, exec); `grep kubectl` is no call
CALL = re.compile(r"(?:^|[;&|(`]|\$\()\s*(?:(?:sudo|env|xargs|watch|time|exec)\s+)*(?:\w+=\S*\s+)*"
                  r"(?:\S*/)?(kubectl|helm)\s+([^;&|\n]*)", re.M)
HELM_CLUSTER = {"install", "upgrade", "rollback", "uninstall", "delete", "del", "un", "get",
                "list", "ls", "status", "history", "test"}
KUBECTL_LOCAL = {"config", "completion"}


def reason(command):
    if KIND_KUBECONFIG in command:
        return None
    for m in CALL.finditer(command):
        tool, words = m.group(1), m.group(2).split()
        args = [w for w in words if not w.startswith("-")]
        if "--help" in words or "-h" in words or args[:1] == ["help"]:
            continue
        if tool == "kubectl" and (args[:1] and args[0] in KUBECTL_LOCAL
                                  or args[:1] == ["version"] and "--client" in words):
            continue
        # a flag's value reads as an argument (helm -n ns status): any word of the call counts
        if tool == "helm" and not HELM_CLUSTER & set(args):
            continue
        return (f"`{m.group(0).strip()}` reaches whatever cluster the default context names, "
                f"which can be production. Name the e2e cluster: "
                f"`{tool} --kubeconfig {KIND_KUBECONFIG} …` (tests/e2e/README.md), or use a make target.")
    return None


def self_test():
    blocked = ["kubectl apply --dry-run=server -f x.yaml", "kubectl get pods",
               "helm install x charts/global-chart", "cd /x && helm upgrade --install a b",
               "/usr/local/bin/kubectl --context prod get ns", "helm -n ns status x",
               "make check && KUBECONFIG=~/.kube/config kubectl get ns", "echo $(kubectl get ns)",
               "sudo kubectl delete ns x"]
    allowed = ["kubectl --kubeconfig .bin/kind-kubeconfig get pods",
               "KUBECONFIG=.bin/kind-kubeconfig helm status x", "kubectl config get-contexts",
               "kubectl version --client", "helm template x charts/global-chart",
               "helm lint charts/global-chart", "make e2e", "kubectl get --help",
               "git commit -m 'kubectl-free'", "grep -n kubectl tests/e2e/README.md",
               "rg 'helm install' docs/"]
    for c in blocked:
        assert reason(c), f"not blocked: {c}"
    for c in allowed:
        assert not reason(c), f"blocked: {c}"
    print("    OK: self-test")


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    try:
        command = json.load(sys.stdin).get("tool_input", {}).get("command", "")
    except (json.JSONDecodeError, AttributeError) as e:
        print(f"kind-kubeconfig-only: cannot read the hook input: {e}", file=sys.stderr)
        sys.exit(2)
    why = reason(command)
    if why:
        print(why, file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
