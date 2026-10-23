#!/usr/bin/env python3
"""Verify rendered random credentials against the standard htpasswd SHA format.

No YAML dependency: extract only the three base64-encoded Secret data fields
whose format the rendering suite asserts. Never print generated credentials.
Run by make unit-test alongside helm-unittest.
"""
import base64
import hashlib
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def check():
    passwords = set()
    for _ in range(8):
        result = subprocess.run(
            ["helm", "template", "auth-check", str(ROOT / "charts/global-chart"),
             "-f", str(ROOT / "tests/httproute-basic-auth.yaml"),
             "--api-versions", "gateway.networking.k8s.io/v1/HTTPRoute",
             "--api-versions", "gateway.envoyproxy.io/v1alpha1/SecurityPolicy",
             "--show-only", "templates/securitypolicy.yaml"],
            capture_output=True, text=True,
        )
        if result.returncode:
            return "helm template could not render the Basic Auth scenario (check it with make render)"
        secrets = []
        for doc in result.stdout.split("\n---"):
            if "\nkind: Secret\n" not in doc:
                continue
            fields = dict(re.findall(r'^  (username|password|\.htpasswd): "([A-Za-z0-9+/=]+)"$', doc, re.M))
            if len(fields) != 3:
                return "generated Secret must contain username, password and .htpasswd as base64 data"
            try:
                data = {k: base64.b64decode(v, validate=True).decode("ascii") for k, v in fields.items()}
            except (ValueError, UnicodeError):
                return "generated credentials are not valid base64-encoded ASCII"
            if not re.fullmatch(r"[A-Za-z0-9]{32}", data["password"]):
                return "random password must contain 32 alphanumeric characters"
            digest = base64.b64encode(hashlib.sha1(data["password"].encode("ascii")).digest()).decode("ascii")
            if data[".htpasswd"] != data["username"] + ":{SHA}" + digest:
                return "htpasswd hash does not authenticate the stored password"
            if data["password"] in passwords:
                return "separate routes or renders reused a random password"
            passwords.add(data["password"])
            secrets.append(data["username"])
        if secrets != ["dev", "admin"]:
            return "expected independent credentials for the single route and the named route"
    return None


if __name__ == "__main__":
    try:
        problem = check()
    except OSError as exc:
        problem = f"could not execute helm: {exc}"
    if problem:
        print(f"    FAIL: Basic Auth: {problem}")
        sys.exit(1)
    print("    OK: random credentials authenticate against the rendered htpasswd hash")
