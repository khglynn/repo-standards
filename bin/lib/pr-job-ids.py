#!/usr/bin/env python3
"""List the job ids a repo actually runs on pull requests.

    python3 bin/lib/pr-job-ids.py <path to a checkout>

Prints one `job_id<TAB>workflow file<TAB>displayed name` line per job, for every workflow
triggered by `pull_request` or `pull_request_target`.

WHY THIS EXISTS: a required status check is a free-text CONTEXT string, and GitHub will
happily accept one that nothing ever reports. A typo (`check` for `checks`) creates a gate
that can never go green — the admin bypasses it and never notices, while every Dependabot
PR queues auto-merge and hangs forever. `bin/enroll` checks its --ci-check against this
list before creating a ruleset. Written 2026-09-11.

Job IDS, not `name:` values: the context GitHub reports is the id unless the job sets a
name, and the id is what every one of Kevin's repos uses today. The displayed name is
printed alongside only so a human can recognise the job in the Actions tab.
"""
import glob
import os
import sys

import yaml


def triggers_of(doc: dict):
    """`on:` is parsed by PyYAML as the boolean True (YAML 1.1 treats `on` as a bool),
    so a naive doc.get("on") finds nothing. Check both spellings, and normalise the
    three shapes GitHub allows: a string, a list, or a mapping."""
    raw = doc.get("on", doc.get(True)) or {}
    if isinstance(raw, str):
        return {raw}
    if isinstance(raw, list):
        return set(raw)
    if isinstance(raw, dict):
        return set(raw)
    return set()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: pr-job-ids.py <path to a checkout>", file=sys.stderr)
        return 2
    root = sys.argv[1]
    patterns = (".github/workflows/*.yml", ".github/workflows/*.yaml")
    for path in sorted(p for pat in patterns for p in glob.glob(os.path.join(root, pat))):
        try:
            with open(path, encoding="utf-8") as fh:
                doc = yaml.safe_load(fh)
        except (OSError, yaml.YAMLError):
            # An unparseable workflow is not this script's problem to report — actionlint
            # in the target repo is. Skipping it only ever makes this list shorter, which
            # fails in the safe direction: enroll refuses a name it cannot see.
            continue
        if not isinstance(doc, dict):
            continue
        if not triggers_of(doc) & {"pull_request", "pull_request_target"}:
            continue
        for job_id, job in (doc.get("jobs") or {}).items():
            name = job.get("name") if isinstance(job, dict) and job.get("name") else job_id
            print(f"{job_id}\t{os.path.basename(path)}\t{name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
