"""What bound-sweep.py and api-verdict.py share to reach the kind API server.

Both send rendered manifests to a server-side dry run with strict field
validation, take `<chart> <file>... [-- <helm flags>...]`, and must report a
missing tool or an unreachable cluster as a FAIL (CODING_STANDARDS.md, *Check
scripts*), never as a traceback.
"""
import shutil
import subprocess
import sys


def split_args(argv):
    """(positional arguments, helm flags after `--`)."""
    if "--" not in argv:
        return argv, []
    i = argv.index("--")
    return argv[:i], argv[i + 1:]


def require_api_server(target):
    """Exit 1 with a FAIL line when helm is missing or KUBECONFIG reaches no API server; target starts kind."""
    if not shutil.which("helm"):
        print("    FAIL: helm: not found on PATH")
        sys.exit(1)
    try:
        ready = subprocess.run(["kubectl", "get", "--raw", "/readyz"], capture_output=True, text=True)
    except FileNotFoundError:
        ready = None
    if ready is None or ready.returncode != 0:
        print(f"    FAIL: kubectl: no API server reachable through KUBECONFIG; make {target} starts the kind cluster: "
              + (" ".join(ready.stderr.split())[:200] if ready else "kubectl not found"))
        sys.exit(1)


def dry_run(manifest):
    """None when the API server accepts manifest, else its whole error on one line."""
    out = subprocess.run(["kubectl", "apply", "--dry-run=server", "--validate=strict", "-n", "default", "-f", "-"],
                         input=manifest, capture_output=True, text=True)
    return None if out.returncode == 0 else " ".join(l.strip() for l in out.stderr.splitlines() if l.strip()) or "refused"
