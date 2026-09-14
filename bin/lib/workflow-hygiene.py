#!/usr/bin/env python3
"""Two cheap hygiene checks over GitHub Actions workflow files.

    workflow-hygiene.py --default-branch main .github/workflows/*.yml
    cat ci.yml | workflow-hygiene.py --default-branch main --stdin --name ci.yml

Prints one JSON object:

    {"parser": "pyyaml",
     "missing_timeout": ["ci.yml:checks"],
     "double_trigger":  ["ci.yml"],
     "unparsed":        []}

Both findings are WARNINGS, never drift — see the reasoning on each below. Written
2026-09-14 for `bin/audit --digest` (spec: khglynn/repo-standards#1).

WHY `timeout-minutes` MATTERS
A job without one inherits GitHub's default of **six hours**. The private-repo allowance
is 3,000 minutes a month, so a single hung job can eat an eighth of the month's budget
while looking, in the UI, exactly like a job that is still working. eachie had two such
jobs (BUILD-LOG, 2026-09-11).

THE ONE EXCLUSION THAT MATTERS: a job that is only `uses:` — a caller pointing at a
reusable workflow — **may not** carry `timeout-minutes`; GitHub rejects the file. Every
repo enrolled in this standard has exactly such a job (the ten-line stub), so a checker
that did not skip them would report a warning on every enrolled repo forever, and the
only way to clear it would be to write a file that does not validate. Skipped, and said
out loud, because "the check is wrong" is how a check gets ignored.

WHY THE DOUBLE TRIGGER IS ONLY A WARNING
A workflow listening on both `push` (to branches other than the default) and
`pull_request` runs twice for every commit on a pull-request branch: once for the push,
once for the PR. That is double the minutes for one commit. But it is sometimes
deliberate — a repo may genuinely want a branch gate before a PR exists — so this is
reported, never counted as drift. Push-on-tags-only alongside `pull_request` is NOT a
double trigger and is not reported.

PARSER: PyYAML when it is importable, a deliberately conservative regex when it is not
(the cloud sessions that run the weekly digest may not have it). The `parser` field says
which ran, because the regex path can only see the `timeout-minutes` half honestly and
says so by leaving `double_trigger` empty rather than guessing.

One YAML trap worth naming: in YAML 1.1, which PyYAML implements, the bare key `on:`
parses as the boolean **True**, not the string "on". Every reader of a workflow file has
to look for both, and the ones that do not silently see a workflow with no triggers.
"""
import argparse
import json
import os
import re
import sys

# WORKFLOW_HYGIENE_NO_YAML=1 forces the regex path. It exists so CI can test the
# fallback on a machine that HAS PyYAML — otherwise the branch that runs on the hosts we
# care about least (and can debug least) would be the only one never exercised.
if os.environ.get("WORKFLOW_HYGIENE_NO_YAML") == "1":
    HAVE_YAML = False
else:
    try:
        import yaml  # type: ignore
        HAVE_YAML = True
    except ImportError:  # pragma: no cover - hosts without PyYAML
        HAVE_YAML = False


def _triggers(doc):
    """Return the `on:` mapping, normalised, handling the YAML-1.1 `on` -> True trap."""
    raw = None
    for key in ("on", True):
        if isinstance(doc, dict) and key in doc:
            raw = doc[key]
            break
    if raw is None:
        return {}
    if isinstance(raw, str):
        return {raw: None}
    if isinstance(raw, list):
        return {str(k): None for k in raw}
    if isinstance(raw, dict):
        return {str(k): v for k, v in raw.items()}
    return {}


def _double_trigger(doc, default_branch):
    """True when push and pull_request will both fire for a commit on a PR branch."""
    trig = _triggers(doc)
    if "push" not in trig or "pull_request" not in trig:
        return False
    cfg = trig["push"]
    if not isinstance(cfg, dict):
        cfg = {}
    branches = cfg.get("branches")
    ignore = cfg.get("branches-ignore")
    if branches is None and ignore is None:
        # No branch filter at all. If the push filter is tags-only, a PR branch commit
        # never fires it — that is not a double run.
        if cfg.get("tags") is not None or cfg.get("tags-ignore") is not None:
            return False
        return True
    if ignore is not None:
        # "everything except these" still covers ordinary feature branches unless the
        # ignore list is doing something exotic; report it and let a human read it.
        return True
    if not isinstance(branches, list):
        branches = [branches]
    extra = [str(b) for b in branches if str(b) != default_branch]
    return bool(extra)


def _jobs_missing_timeout(doc):
    jobs = doc.get("jobs") if isinstance(doc, dict) else None
    if not isinstance(jobs, dict):
        return []
    missing = []
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        if "uses" in job:
            continue  # a reusable-workflow caller; timeout-minutes is not allowed here
        if "timeout-minutes" not in job:
            missing.append(str(job_id))
    return missing


# ---------------------------------------------------------------- regex fallback
# Only used when PyYAML is missing. It answers the timeout question and declines the
# trigger question, because guessing at `on:` from text is how a warning system starts
# crying wolf. Job keys sit at 2-4 spaces under `jobs:`; a job's body is everything
# indented deeper than its key.
_JOBS_RE = re.compile(r"^jobs:\s*$", re.M)
_JOB_KEY_RE = re.compile(r"^(\s{2,4})([A-Za-z_][A-Za-z0-9_-]*):\s*(?:#.*)?$")


def _jobs_missing_timeout_regex(text):
    """The same question as _jobs_missing_timeout, answered without a YAML parser.

    THE INDENT IS THE WHOLE TRICK, and the first version of this function got it wrong in
    a way that made the check useless on ordinary workflows. It asked `^\s+uses:` and
    `^\s+timeout-minutes:` — *any* indentation — so a job written in the common style

        unit:
          runs-on: ubuntu-latest
          steps:
            - name: Check out
              uses: actions/checkout@v5

    looked like a reusable-workflow caller (because one of its STEPS says `uses:`) and was
    skipped silently. Every such job — which is most of them — went unchecked, and the
    mirror bug let a STEP's own `timeout-minutes:` satisfy the JOB-level check it is not.
    The regex path is the path a cloud routine takes (no PyYAML), so the weekly digest
    would have reported "no repos have this problem" forever. Found by review 2026-09-14.

    A job's own keys sit exactly two spaces deeper than its key, so both questions are
    anchored to that column and nothing nested below it can answer them.
    """
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if _JOBS_RE.match(line):
            start = i + 1
            break
    if start is None:
        return []
    missing = []
    current = None
    indent = None
    body = []

    def close(job_indent):
        if current is None:
            return
        joined = "\n".join(body)
        col = " " * (job_indent + 2)  # the job's OWN keys, not its steps'
        if re.search(r"^%suses:" % col, joined, re.M):
            return  # a reusable-workflow caller; timeout-minutes is not allowed here
        if not re.search(r"^%stimeout-minutes:" % col, joined, re.M):
            missing.append(current)

    for line in lines[start:]:
        if line.strip() and not line.startswith(" "):
            break  # back to a top-level key: jobs: is over
        m = _JOB_KEY_RE.match(line)
        if m and (indent is None or len(m.group(1)) == indent):
            close(indent if indent is not None else 0)
            indent = len(m.group(1))
            current = m.group(2)
            body = []
            continue
        if current is not None:
            body.append(line)
    close(indent if indent is not None else 0)
    return missing


def scan(name, text, default_branch):
    """Scan one workflow's text. Returns (missing_timeout_jobs, double_trigger, parsed)."""
    if HAVE_YAML:
        try:
            doc = yaml.safe_load(text)
        except Exception:
            return [], False, False
        if not isinstance(doc, dict):
            return [], False, False
        return _jobs_missing_timeout(doc), _double_trigger(doc, default_branch), True
    return _jobs_missing_timeout_regex(text), False, True


def scan_many(items, default_branch):
    """items: iterable of (workflow name, text). Returns the JSON-shaped result dict."""
    out = {
        "parser": "pyyaml" if HAVE_YAML else "regex",
        "missing_timeout": [],
        "double_trigger": [],
        "unparsed": [],
    }
    for name, text in items:
        missing, double, parsed = scan(name, text, default_branch)
        if not parsed:
            out["unparsed"].append(name)
            continue
        out["missing_timeout"].extend("%s:%s" % (name, j) for j in missing)
        if double:
            out["double_trigger"].append(name)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("files", nargs="*")
    ap.add_argument("--default-branch", default="main")
    ap.add_argument("--stdin", action="store_true")
    ap.add_argument("--name", default="stdin.yml")
    args = ap.parse_args()

    items = []
    if args.stdin:
        items.append((args.name, sys.stdin.read()))
    for path in args.files:
        with open(path, encoding="utf-8") as fh:
            items.append((os.path.basename(path), fh.read()))
    if not items:
        ap.error("give at least one file, or --stdin")
    json.dump(scan_many(items, args.default_branch), sys.stdout, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
