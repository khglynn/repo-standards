#!/usr/bin/env python3
"""Per-repo GitHub Actions facts for `bin/audit`, gathered concurrently.

    printf 'eachie\\tmain\\tPUBLIC\\n' | bin/lib/actions-scan.py --owner khglynn

Reads a TSV of `name<TAB>default_branch<TAB>visibility` on stdin and prints one JSON
object keyed by repo name:

    {"eachie": {"approve": true,
                "runs": 416, "timed": 300, "capped": true,
                "minutes": 812, "runners": ["UBUNTU"],
                "missing_timeout": ["ci.yml:unit"],
                "double_trigger": [],
                "unparsed": [], "parser": "pyyaml",
                "errors": []}}

READ-ONLY BY CONSTRUCTION. There is exactly one HTTP call site below and it issues GET
and nothing else; `bin/audit` is a thing you can run at 2am without thinking about it,
and that property is worth more than any feature this file could grow.

WHY THIS IS A SEPARATE, CONCURRENT PROCESS
The minutes estimate needs one `/timing` call per run, and the account runs ~1,320 of
them a month (measured 2026-09-14: eachie 416, list-maker 268, remembrall 263). Inside
`bin/audit`'s serial bash loop that is twenty minutes. Here it is one pool.

WHY NOT THE BILLING ENDPOINTS
`GET /users/{u}/settings/billing/actions` needs a classic token with the `user` scope,
and the newer enhanced-billing endpoints need their own. This machine's token has
`admin:org, gist, repo, workflow` — none of them — and minting a broad classic PAT so a
read-only monitor can see one number is a worse secret than the problem it solves
(repo-standards#1 says the same). So the number here is derived from run timings and is
labelled an estimate everywhere it is printed.

HOW THE MINUTES ARE COUNTED, AND THE MEASUREMENT THAT CHANGED THE METHOD
`minutes` is GitHub's own billing rule rebuilt from `/actions/runs/{id}/jobs`: **each job,
rounded up to the whole minute**, skipped jobs excluded, times the runner multiplier
(Linux 1x, Windows 2x, macOS 10x, read from each job's `labels`).

Two dead ends are worth writing down so nobody spends the hour again.

**The `billable` block in `/actions/runs/{id}/timing` is all zeros on this account.**
`billable.UBUNTU.total_ms: 0`, every `job_runs[].duration_ms: 0` — on private repos as
well as public, on completed successful runs (checked by hand across eachie, kevinhg-com
and repo-standards, 2026-09-14). Reading the obvious field would have reported "0 minutes
used" for the whole account, confidently, forever.

**Wall-clock per run (`run_duration_ms`, which the brief asked for) reads LOW, and the
first measurement of how low was wrong.** Sampling eachie's 100 most recent runs put
wall-clock within 1% of the per-job figure, which looked like a licence to use the cheaper
call. Widening the sample to every private repo for 09-01..09-11 — 655 runs — put them
**2,573 against 2,962 minutes, 15% apart**: the recent sample happened to be runs that put
almost nothing in parallel, and a run whose jobs overlap bills the sum and measures the
max. For a number whose entire job is to warn before a budget is exhausted, 15% low is
the wrong direction to be wrong in, so the per-job figure won. Same call count, larger
responses, about 20 seconds more across the account.

Sanity check against a real invoice, such as it can be: GitHub's own billing page read
2,058 private minutes at some point on 2026-09-11 (BUILD-LOG). This method gives 1,776
for 09-01..09-10 and 2,962 for 09-01..09-11, so the known figure falls inside the bracket
where a mid-day-11 snapshot should fall. That is corroboration, not proof.

It is still an estimate and is labelled one everywhere it is printed. Larger runners
(`ubuntu-latest-8-core` and friends) bill at their own per-minute rates rather than a
multiplier and this applies none; retries and billing-period boundaries move things; a run
still in flight reports nothing yet. And the billing endpoints, which would settle it, need
token scopes this token does not have and should not be given for a read-only monitor
(repo-standards#1 reaches the same conclusion).

Written 2026-09-14. Spec: khglynn/repo-standards#1.
"""
import argparse
import base64
import concurrent.futures as futures
import datetime as dt
import importlib.util
import json
import math
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
# GitHub's published multipliers for standard runners, applied per job in _runner_of().
MULTIPLIER = {"UBUNTU": 1, "WINDOWS": 2, "MACOS": 10}

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "workflow_hygiene", os.path.join(_here, "workflow-hygiene.py"))
hygiene = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hygiene)


class Client:
    """The one HTTP call site. GET only, with a bounded retry for the rate limiter.

    The retry is BOUNDED on purpose. An earlier version slept whenever the response said
    `X-RateLimit-Remaining: 0`, which is right for a brief secondary throttle and
    catastrophic for the primary one: the hourly 5,000 was genuinely exhausted, every
    worker slept, and `bin/audit` sat there looking like a hang for fifteen minutes with
    nothing to show for it (2026-09-14). A tool that waits silently is worse than one that
    says "I could not finish, here is why". `sleep_budget` is the whole run's allowance.
    """

    def __init__(self, token, sleep_budget=90):
        self.token = token
        self.sleep_left = sleep_budget
        self.exhausted = False

    def _nap(self, seconds):
        seconds = min(seconds, self.sleep_left, 20)
        if seconds <= 0:
            return False
        self.sleep_left -= seconds
        time.sleep(seconds)
        return True

    def rate_remaining(self):
        """How many calls are really left, and when the budget resets.

        DO NOT USE `/rate_limit` FOR THIS. On 2026-09-14 that endpoint reported
        `remaining: 5000, used: 0` while every real call came back 403 "API rate limit
        exceeded for user ID 19673024" — the 403's own headers saying `Remaining: 0,
        Used: 5000`. The endpoint reports a token bucket; the throttle that actually bites
        is applied at the user level across everything. Trusting `/rate_limit` cost a
        whole audit run that produced a complete, confident, entirely empty report: forty
        repos all reading "could not read this repo's file list".

        So this probes with a real, cheap call and reads the headers off it. One call
        spent to avoid spending fifteen hundred.
        """
        req = urllib.request.Request(API + "/user", method="GET")
        req.add_header("Authorization", "Bearer " + self.token)
        req.add_header("Accept", "application/vnd.github+json")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                headers = resp.headers
        except urllib.error.HTTPError as exc:
            headers = exc.headers
        except Exception:
            return None, None
        try:
            return int(headers.get("X-RateLimit-Remaining")), int(headers.get("X-RateLimit-Reset"))
        except (TypeError, ValueError):
            return None, None

    def get(self, path, tries=4):
        url = path if path.startswith("http") else API + "/" + path.lstrip("/")
        last = None
        for attempt in range(tries):
            req = urllib.request.Request(url, method="GET")
            req.add_header("Authorization", "Bearer " + self.token)
            req.add_header("Accept", "application/vnd.github+json")
            req.add_header("X-GitHub-Api-Version", "2022-11-28")
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    return json.loads(resp.read().decode("utf-8") or "null"), resp.headers
            except urllib.error.HTTPError as exc:
                last = exc
                # 403/429 with the rate limiter behind it: wait and try again. Anything
                # else (404 on a repo with Actions off, 403 on a fork) is a real answer.
                if exc.code in (403, 429) and attempt < tries - 1:
                    retry_after = exc.headers.get("Retry-After")
                    remaining = exc.headers.get("X-RateLimit-Remaining")
                    used = exc.headers.get("X-RateLimit-Used")
                    limit = exc.headers.get("X-RateLimit-Limit")
                    if remaining == "0" and used == limit:
                        # The hourly budget is gone. No amount of waiting inside this run
                        # fixes it; say so once and let every other call fail fast.
                        self.exhausted = True
                        return None, exc
                    if self._nap(int(retry_after) if retry_after else 2 ** attempt):
                        continue
                return None, exc
            except Exception as exc:  # network hiccup
                last = exc
                if attempt < tries - 1:
                    time.sleep(2 ** attempt)
                    continue
                return None, exc
        return None, last


def month_start(today):
    return today.replace(day=1)


def scan_repo_phase1(client, name, default_branch, owner, since, cap):
    """Everything for one repo except the per-run timing calls."""
    out = {"approve": None, "runs": 0, "capped": False, "run_ids": [],
           "missing_timeout": [], "double_trigger": [], "unparsed": [],
           "parser": "pyyaml" if hygiene.HAVE_YAML else "regex", "errors": []}
    repo = "%s/%s" % (owner, name)

    # --- (a) "Allow GitHub Actions to create and approve pull requests"
    # The switch whose absence silently stranded three list-maker PRs on 2026-09-14:
    # the workflow's `gh pr review --approve` is refused, so a repo with a one-approval
    # rule queues auto-merge behind a review that can never arrive.
    data, err = client.get("repos/%s/actions/permissions/workflow" % repo)
    if data is not None:
        out["approve"] = data.get("can_approve_pull_request_reviews")
    else:
        out["errors"].append("approve-switch unreadable (%s)" % _why(err))

    # --- (b) runs this billing month, newest first, paginated, capped
    page = 1
    while len(out["run_ids"]) < cap:
        path = ("repos/%s/actions/runs?created=%%3E%%3D%s&per_page=100&page=%d"
                % (repo, since, page))
        data, err = client.get(path)
        if data is None:
            out["errors"].append("run list unreadable (%s)" % _why(err))
            break
        runs = data.get("workflow_runs") or []
        if not runs:
            break
        for run in runs:
            # A run still in progress has no final timing; counting it would make the
            # estimate jitter downward on re-runs. Skipped, and counted in `runs` so the
            # number of runs stays honest.
            out["runs"] += 1
            if run.get("status") == "completed" and len(out["run_ids"]) < cap:
                out["run_ids"].append(run["id"])
        if len(runs) < 100:
            break
        page += 1
        if page > 20:  # 2,000 runs in a month from one repo: stop and say so
            break
    # `runs` is every run this month; `run_ids` is only the COMPLETED ones, which are the
    # only ones with a final cost. So `runs > len(run_ids)` is the normal state whenever
    # something is mid-flight and must not be read as "the cap was hit" — capped means
    # exactly one thing: there were more completed runs than we agreed to measure.
    data, _ = client.get("repos/%s/actions/runs?created=%%3E%%3D%s&per_page=1" % (repo, since))
    if isinstance(data, dict) and data.get("total_count") is not None:
        out["runs"] = data["total_count"]
    out["capped"] = len(out["run_ids"]) >= cap

    # --- (c)+(d) the workflow files
    data, err = client.get("repos/%s/contents/.github/workflows" % repo)
    if isinstance(data, list):
        items = []
        for entry in data:
            if entry.get("type") != "file" or not entry.get("name", "").endswith((".yml", ".yaml")):
                continue
            blob, berr = client.get(entry["url"])
            if not isinstance(blob, dict) or "content" not in blob:
                out["errors"].append("could not read %s (%s)" % (entry["name"], _why(berr)))
                continue
            try:
                text = base64.b64decode(blob["content"]).decode("utf-8", "replace")
            except Exception:
                out["errors"].append("could not decode %s" % entry["name"])
                continue
            items.append((entry["name"], text))
        found = hygiene.scan_many(items, default_branch)
        out["missing_timeout"] = found["missing_timeout"]
        out["double_trigger"] = found["double_trigger"]
        out["unparsed"] = found["unparsed"]
        out["parser"] = found["parser"]
    # A repo with no .github/workflows 404s here. That is an answer, not an error.
    return out


def _why(err):
    if err is None:
        return "no response"
    code = getattr(err, "code", None)
    return "HTTP %s" % code if code else type(err).__name__


def _runner_of(labels):
    """Runner family and multiplier from a job's labels. Unknown labels bill as 1x."""
    text = " ".join(str(x).lower() for x in (labels or []))
    if "macos" in text or "mac-" in text:
        return "MACOS", 10
    if "windows" in text or "win-" in text:
        return "WINDOWS", 2
    return "UBUNTU", 1


def wall_minutes(client, repo, run_id):
    """The cheap fallback: wall-clock per run, one tiny response. Reads LOW — see the
    module docstring — which is why it is never the first choice."""
    data, err = client.get("repos/%s/actions/runs/%d/timing" % (repo, run_id))
    if not isinstance(data, dict):
        return 0, [], _why(err)
    return (data.get("run_duration_ms") or 0) / 60000.0, sorted((data.get("billable") or {}).keys()), None


def run_minutes(client, repo, run_id):
    """(billed-estimate minutes, runner families seen, error) for one run."""
    minutes = 0
    families = []
    page = 1
    while True:
        data, err = client.get("repos/%s/actions/runs/%d/jobs?per_page=100&page=%d"
                               % (repo, run_id, page))
        if not isinstance(data, dict):
            return 0, [], _why(err)
        jobs = data.get("jobs") or []
        for job in jobs:
            # A skipped job costs nothing. Everything that actually ran costs at least
            # one whole minute, which is why short jobs are expensive in aggregate.
            if job.get("conclusion") == "skipped":
                continue
            started, finished = job.get("started_at"), job.get("completed_at")
            if not started or not finished:
                continue
            try:
                seconds = (_ts(finished) - _ts(started)).total_seconds()
            except Exception:
                continue
            if seconds <= 0:
                continue
            family, mult = _runner_of(job.get("labels"))
            if family not in families:
                families.append(family)
            minutes += int(math.ceil(seconds / 60.0)) * mult
        if len(jobs) < 100 or page >= 5:
            break
        page += 1
    return minutes, families, None


def _ts(value):
    return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--owner", required=True)
    ap.add_argument("--since", default=None, help="YYYY-MM-DD; default the 1st of this month")
    ap.add_argument("--cap", type=int, default=300, help="max runs timed per repo")
    ap.add_argument("--workers", type=int, default=6,
                    help="6 keeps this inside GitHub's burst behaviour; 10 tripped it")
    ap.add_argument("--method", choices=["jobs", "timing", "auto"], default="auto",
                    help="jobs = GitHub's per-job billing rule (accurate, ~1 call per run "
                         "and a large response); timing = wall-clock per run (cheap, reads "
                         "low); auto = jobs unless the hourly API budget cannot cover it")
    ap.add_argument("--progress", action="store_true", help="dots on stderr")
    ap.add_argument("--preflight", action="store_true",
                    help="print the real remaining API budget and exit; 3 means exhausted")
    args = ap.parse_args()

    since = args.since or month_start(dt.date.today()).isoformat()

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        try:
            token = subprocess.run(["gh", "auth", "token"], capture_output=True,
                                   text=True, check=True).stdout.strip()
        except Exception as exc:
            print("actions-scan: no GitHub token (%s)" % exc, file=sys.stderr)
            sys.exit(1)
    client = Client(token)

    if args.preflight:
        remaining, reset = client.rate_remaining()
        if remaining is None:
            print("unknown")
            sys.exit(0)
        if remaining < 200:
            when = dt.datetime.fromtimestamp(reset).strftime("%H:%M") if reset else "soon"
            print("exhausted %d %s" % (remaining, when))
            sys.exit(3)
        print("ok %d" % remaining)
        sys.exit(0)

    repos = []
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        name = parts[0]
        branch = parts[1] if len(parts) > 1 and parts[1] else "main"
        vis = parts[2] if len(parts) > 2 else "PUBLIC"
        repos.append((name, branch, vis))

    results = {}
    with futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        jobs = {pool.submit(scan_repo_phase1, client, n, b, args.owner, since, args.cap): n
                for n, b, _ in repos}
        for fut in futures.as_completed(jobs):
            name = jobs[fut]
            try:
                results[name] = fut.result()
            except Exception as exc:
                results[name] = {"approve": None, "runs": 0, "capped": False, "run_ids": [],
                                 "missing_timeout": [], "double_trigger": [], "unparsed": [],
                                 "parser": "unknown",
                                 "errors": ["scan failed: %s" % exc]}
            if args.progress:
                sys.stderr.write(".")
                sys.stderr.flush()

    # Phase 2: every run's cost, one flat pool across all repos.
    #
    # ~1,300 runs a month means ~1,600 API calls for a whole-account audit, a third of the
    # hourly 5,000. Fine weekly, and easy to blow through while iterating — so check the
    # budget BEFORE spending it rather than discovering it a thousand calls in.
    tasks = [(name, rid) for name, r in results.items() for rid in r["run_ids"]]
    method = args.method
    note = None
    if method == "auto":
        remaining, _ = client.rate_remaining()
        if remaining is not None and remaining < len(tasks) * 1.2:
            method = "timing"
            note = ("API budget short (%s calls left, %d runs to measure), so minutes were "
                    "measured the cheap way and read LOW" % (remaining, len(tasks)))
        else:
            method = "jobs"
    measure = run_minutes if method == "jobs" else wall_minutes
    for r in results.values():
        r["minutes"] = 0
        r["runners"] = []
        r["timed"] = 0
    with futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        jobs = {pool.submit(measure, client, "%s/%s" % (args.owner, name), rid): name
                for name, rid in tasks}
        for fut in futures.as_completed(jobs):
            name = jobs[fut]
            try:
                billed, runners, err = fut.result()
            except Exception as exc:
                results[name]["errors"].append("job timing failed: %s" % exc)
                continue
            if err:
                results[name]["errors"].append("job timing unreadable (%s)" % err)
                continue
            results[name]["minutes"] += billed
            results[name]["timed"] += 1
            for runner in runners:
                if runner not in results[name]["runners"]:
                    results[name]["runners"].append(runner)
            if args.progress:
                sys.stderr.write(".")
                sys.stderr.flush()

    for r in results.values():
        r["minutes"] = int(round(r["minutes"]))
        r["runners"] = sorted(r["runners"])
        if client.exhausted:
            r["errors"].append("hourly GitHub API budget exhausted mid-run; "
                               "minutes are incomplete and read LOW")
        # Errors repeat once per run when a whole repo is unreadable; collapse them.
        seen = []
        for e in r["errors"]:
            if e not in seen:
                seen.append(e)
        r["errors"] = seen
        del r["run_ids"]
    if args.progress:
        sys.stderr.write("\n")
    json.dump({"since": since, "cap": args.cap, "method": method,
               "note": note, "repos": results}, sys.stdout, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
