#!/usr/bin/env python3
"""The rules of what a workload-scope job inherits live in three places (issue
#245): the source of truth, the `inherited:` / `cronjobs only:` / `never:` lines
of the jobPodSpec header in _job-helpers.tpl, and two copies for the values
author (ADR 0019): values.schema.json and docs/values-authors/README.md. This
holds both copies to the header:

- each workload property whose description says "Inherited by the workload's
  hooks and cronjobs", "Inherited by the workload's cronjobs, not by its hooks"
  or "Never/Not inherited by the workload's hooks and cronjobs" is on that line
  of the header, and each header field the workload declares says it;
- the workload's `hooks` and `cronJobs` descriptions list exactly the fields
  the header gives each ("They inherit the workload's ...; never ...");
- the guide's inherited sentence and its "Never inherited" bullet name exactly
  the header's fields, in backticks.

Usage: check-inheritance.py <chart dir> <guide>
"""
import json
import pathlib
import re
import sys

MARKS = {"inherited": r"Inherited by the workload's hooks and cronjobs",
         "cronjobs only": r"Inherited by the workload's cronjobs, not by its hooks",
         "never": r"(Never|Not) inherited by the workload's hooks and cronjobs"}


def names(text):
    """The field names of a prose list: "a, b and c" or "a, b or c"."""
    return {n for n in re.split(r",\s*|\s+and\s+|\s+or\s+", text.strip()) if n}


def main(chart, guide):
    header = (chart / "templates" / "_job-helpers.tpl").read_text()
    rules = {k: set(m.group(1).split()) for k in MARKS
             if (m := re.search(rf"^\s*{k}: (.+)$", header, re.M))}
    if set(rules) != set(MARKS):
        return [f"_job-helpers.tpl: the jobPodSpec header lacks a `{k}:` line" for k in MARKS if k not in rules]
    findings = []

    workload = json.loads((chart / "values.schema.json").read_text())["$defs"]["deployment"]["properties"]
    for field, prop in workload.items():
        desc = prop.get("description", "")
        marked = next((k for k, mark in MARKS.items() if re.search(mark, desc)), None)
        listed = next((k for k, v in rules.items() if field in v), None)
        if marked != listed:
            findings.append(f"values.schema.json: workloads.<name>.{field}: the description says "
                            f"{marked or 'nothing'} about inheritance, the jobPodSpec header {listed or 'nothing'}")
    for field, extra in (("hooks", set()), ("cronJobs", rules["cronjobs only"])):
        m = re.search(r"They inherit the workload's (.+?); never (.+?)\.", workload[field].get("description", ""))
        if not m:
            findings.append(f"values.schema.json: workloads.<name>.{field}: no \"They inherit the workload's ...; "
                            "never ...\" sentence in the description")
            continue
        for got, want, what in ((names(m.group(1)), rules["inherited"] | extra, "inherit"),
                                (names(m.group(2)), rules["never"], "never")):
            if got != want:
                findings.append(f"values.schema.json: workloads.<name>.{field}: \"{what}\" lists "
                                f"{sorted(got - want)} beyond the header and misses {sorted(want - got)}")

    text = guide.read_text()
    for pattern, want, what in ((r"inherits from\s+that workload:(.+?)An\s+explicit value",
                                 rules["inherited"] | rules["cronjobs only"], "inherited"),
                                (r"- Never inherited:(.+?)\.", rules["never"], "never inherited")):
        m = re.search(pattern, text, re.S)
        got = set(re.findall(r"`(\w+)`", m.group(1))) if m else set()
        if got != want:
            findings.append(f"{guide}: the {what} list names {sorted(got - want)} beyond the jobPodSpec header "
                            f"and misses {sorted(want - got)}")
        if what == "inherited" and m:
            findings += [f"{guide}: `{f}` is inherited by cronjobs only, and the guide does not say "
                         "\"for a cronjob only\" after it"
                         for f in rules["cronjobs only"] if not re.search(rf"`{f}`\s+for a cronjob only", m.group(1))]
    return findings


if __name__ == "__main__":
    found = main(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    for f in found:
        print(f"    FAIL: {f}")
    if found:
        sys.exit(1)
    print("    OK: the schema and the guide state the inheritance the jobPodSpec header lists")
