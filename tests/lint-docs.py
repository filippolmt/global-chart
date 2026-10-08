#!/usr/bin/env python3
"""Every file a document or a comment points at must exist.

A pointer to a missing file fails silently: the agent or the reader who follows
it finds nothing, and nothing else in the pipeline notices. Two shapes are
checked:

- In the Markdown documents (CLAUDE.md, GLOSSARY.md, README.md,
  CODING_STANDARDS.md, docs/agents/, tests/e2e/README.md), every path-like
  token in backticks and every relative Markdown link.
- In the comments of templates, suites, values, Makefile and test scripts,
  every reference to a Markdown document (`*.md`) or to an ADR.

A token resolves when it exists from the repository root or from the file's own
directory, or when it is the tail of a tracked path: a basename
(`_hook-helpers.tpl`), or a path relative to a directory the text already
named (`test01/values.01.yaml`, `skip-schema/`). Paths the repository ignores
(`generated-manifests/`, `.bin/`) resolve too: they exist once a target ran.

A reference to a numbered section of CLAUDE.md (`CLAUDE.md pattern 5`) fails
anywhere outside the ADRs and the CHANGELOG: those numbers change whenever
CLAUDE.md is reorganised. Point at the home of the rule instead. ADRs and the
CHANGELOG describe the repository as it was when they were written, so they
are not checked at all.

Usage: lint-docs.py
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

DOCS = ["CLAUDE.md", "GLOSSARY.md", "README.md", "CODING_STANDARDS.md", "tests/e2e/README.md"]
DOC_GLOBS = ["docs/agents/*.md"]
CODE_GLOBS = [
    "charts/global-chart/templates/**/*",
    "charts/global-chart/tests/*.yaml",
    "charts/global-chart/values.yaml",
    "tests/**/*.yaml",
    "tests/**/*.py",
    "Makefile",
]

PATH_EXT = r"(?:md|tpl|yaml|yml|json|py|txt|html)"
# A path-like token: no spaces or template syntax, a directory or a known extension.
PATH_TOKEN = re.compile(r"^[A-Za-z0-9_.\-/]+(?:/|\." + PATH_EXT + r")$")
BACKTICK = re.compile(r"`([^`\n]+)`")
MD_LINK = re.compile(r"\]\(([^)\s#]+)(?:#[^)]*)?\)")
CODE_REF = re.compile(r"(?<![\w/.-])((?:[\w.-]+/)*[\w.-]+\.md|docs/adr/[\w.-]+)")
SECTION_REF = re.compile(r"CLAUDE\.md,? (?:pattern|section|rule) \d+")


def tracked():
    out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return out.split()


def ignored_prefixes():
    prefixes = []
    for line in (ROOT / ".gitignore").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "*" not in line:
            prefixes.append(line.rstrip("/"))
    return prefixes


def resolves(token, source, files, ignored):
    token = token.rstrip("/")
    if not token or token.startswith(("http:", "https:", "mailto:")):
        return True
    if (ROOT / token).exists() or (source.parent / token).exists():
        return True
    if any(("/" + f + "/").find("/" + token + "/") >= 0 or ("/" + f).endswith("/" + token) for f in files):
        return True
    return any(token == p or token.startswith(p + "/") for p in ignored)


def main():
    files = tracked()
    ignored = ignored_prefixes()
    errors = []

    docs = [ROOT / d for d in DOCS]
    for g in DOC_GLOBS:
        docs += sorted(ROOT.glob(g))
    for doc in docs:
        rel = doc.relative_to(ROOT)
        for n, line in enumerate(doc.read_text().splitlines(), 1):
            tokens = [t for t in BACKTICK.findall(line) if PATH_TOKEN.match(t)]
            tokens += MD_LINK.findall(line)
            for t in tokens:
                if not resolves(t, doc, files, ignored):
                    errors.append(f"{rel}:{n}: `{t}` does not exist")
            if rel.name != "CLAUDE.md" and SECTION_REF.search(line):
                errors.append(f"{rel}:{n}: points at a numbered CLAUDE.md section; point at the rule's home")

    code = set()
    for g in CODE_GLOBS:
        code.update(p for p in ROOT.glob(g) if p.is_file() and str(p.relative_to(ROOT)) in files)
    # This script names the forbidden shape in order to describe it.
    code.discard(pathlib.Path(__file__).resolve())
    for path in sorted(code):
        rel = path.relative_to(ROOT)
        for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if SECTION_REF.search(line):
                errors.append(f"{rel}:{n}: points at a numbered CLAUDE.md section; point at the rule's home")
            for t in CODE_REF.findall(line):
                if not resolves(t, path, files, ignored):
                    errors.append(f"{rel}:{n}: `{t}` does not exist")

    if errors:
        print("\n".join(f"    FAIL: {e}" for e in errors))
        return 1
    print(f"    OK: every pointer in {len(docs)} documents and {len(code)} code files resolves")
    return 0


if __name__ == "__main__":
    sys.exit(main())
