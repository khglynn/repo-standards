#!/usr/bin/env python3
"""Open loops for `bin/audit`: the GitHub loose ends nothing else is watching.

    printf 'some-repo\\tmain\\tPRIVATE\\tfalse\\n' | bin/lib/loops-scan.py --owner khglynn

Reads a TSV of `name<TAB>default_branch<TAB>visibility<TAB>is_fork` on stdin and prints one
JSON object: the raw facts it read, the open loops derived from them, and — for every kind
of fact — whether it was actually measured.

WHAT COUNTS AS AN OPEN LOOP (2026-09-22)
Agents open pull requests and nobody notices when they stall. The Dependabot standard
already watched Dependabot; these four are the loose ends it could not see:

  1. Any open pull request older than `--stale-days` (7), whoever opened it, with the ONE
     reason it is not merging: a merge conflict, failing tests, a review the rules still
     require, tests still running, or simply ready and waiting.
  2. A Dependabot pull request with auto-merge QUEUED whose required check has FAILED, at
     any age. GitHub will hold it forever and tell nobody; the shared workflow labels it
     from now on, but this is the net under that net (and under every PR from before).
  3. A default branch whose rules still require an approving review. Kevin retired that
     requirement on 2026-09-15 — in a one-person account the only way past it is an
     admin bypass — so a rule that still asks for one strands green pull requests.
  4. Dependabot security fixes switched on, fixable alerts open, no Dependabot run in
     `--silent-days` (14) and no Dependabot pull request open: the fixes are probably not
     running at all. The last condition is there because a repo whose fix is already
     sitting in an open pull request has no reason to run again — found against a real
     repo on 2026-09-22, where the brief's plain "no run in 14 days" rule would have
     raised a false alarm a week later.

READ-ONLY BY CONSTRUCTION. REST calls go through actions-scan.py's GET-only client. GraphQL
is a POST by protocol, so `Gql.query` refuses any document containing a mutation before a
byte is sent. This file never writes anything, anywhere.

THE TOKEN THE WEEKLY RUN USES, AND WHAT IT CANNOT SEE
The weekly audit runs on a fine-grained, read-only token. Two limits shape this file:

  * Fine-grained tokens CANNOT be given the Checks permission at all — GitHub staff,
    community discussion #129512 (2025-03-03), and the "known gaps" list on GitHub's
    *Managing your personal access tokens* page (read 2026-09-22). So a pull request's
    check runs are unreadable to it, even with every permission ticked. The fallback is
    the Actions API (the token has Actions: read): the jobs that ran on the PR's head
    commit carry the same names as the required checks. Commit statuses (the kind Vercel
    reports) need "Commit statuses: read", which the token does not have today.
  * Security alerts need "Dependabot alerts: read", which it also does not have today.

Anything it cannot read is reported as NOT READ, never as "none" — the rule the rest of
this audit was built on. A check nobody could read is not a passing check.

Written 2026-09-22 for the open-loops sweep.
"""
import argparse
import concurrent.futures as futures
import datetime as dt
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("actions_scan", os.path.join(_here, "actions-scan.py"))
scan = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scan)

STALE_DAYS = 7
SILENT_DAYS = 14
# What GitHub itself treats as "this required check did not pass". CANCELLED and STALE are
# in on purpose: a required check that was cancelled on the current head blocks the merge
# exactly as hard as a failure does, and auto-merge waits on it forever.
FAILED = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE",
          "STALE", "ERROR"}
PASSED = {"SUCCESS", "NEUTRAL", "SKIPPED"}


# ------------------------------------------------------------------ GraphQL, reads only
class Gql:
    """POST to /graphql with a query document, and nothing else.

    A GraphQL read is a POST by protocol, so "GET only" cannot be the guarantee here the
    way it is in actions-scan.py. The guarantee is this: a document that mentions a
    mutation is refused before anything is sent.
    """

    def __init__(self, token):
        self.token = token

    def query(self, document, variables=None):
        if re.search(r"\bmutation\b", document, re.I):
            raise ValueError("loops-scan is read-only; refusing a GraphQL mutation")
        body = json.dumps({"query": document, "variables": variables or {}}).encode()
        req = urllib.request.Request(scan.API + "/graphql", data=body, method="POST")
        req.add_header("Authorization", "Bearer " + self.token)
        req.add_header("Content-Type", "application/json")
        last = None
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=40) as resp:
                    payload = json.loads(resp.read().decode("utf-8") or "{}")
                # GraphQL answers 200 with an `errors` list for a field it will not give
                # this token — the fine-grained token's check runs, for one. The data that
                # WAS readable comes back beside it, so both are returned and the caller
                # decides what the errors cost.
                return payload.get("data"), payload.get("errors") or [], None
            except urllib.error.HTTPError as exc:
                last = exc
                if exc.code in (403, 429, 502, 503) and attempt < 2:
                    time.sleep(2 ** attempt)
                    continue
                return None, [], exc
            except Exception as exc:  # network hiccup
                last = exc
                if attempt < 2:
                    time.sleep(2 ** attempt)
                    continue
                return None, [], exc
        return None, [], last


def _why(err):
    return scan._why(err)


def _next_link(headers):
    """The rel="next" URL from a Link header, or None."""
    link = (headers.get("Link") if hasattr(headers, "get") else None) or ""
    for part in link.split(","):
        m = re.search(r'<([^>]+)>\s*;\s*rel="next"', part)
        if m:
            return m.group(1)
    return None


def _days(created, today):
    try:
        d = dt.datetime.fromisoformat(str(created).replace("Z", "+00:00")).date()
    except Exception:
        return None
    return (today - d).days


# ------------------------------------------------------------------ rules
def read_rules(client, repo, branch):
    """The default branch's required checks and required approving reviews.

    Rulesets first (`/rules/branches/{b}` — the ACTIVE rules on that branch, from every
    ruleset that targets it, readable without admin), classic branch protection only when
    the branch has no rules at all. `approvals` is None when it could not be read, never 0.
    """
    out = {"read": True, "required": [], "approvals": 0, "source": None,
           "ruleset_ids": [], "errors": []}
    esc = branch.replace("/", "%2F")
    rules = []
    page = 1
    while True:
        data, err = client.get("repos/%s/rules/branches/%s?per_page=100&page=%d" % (repo, esc, page))
        if not isinstance(data, list):
            out["read"] = False
            out["approvals"] = None
            out["errors"].append("rules unreadable (%s)" % _why(err))
            return out
        rules.extend(data)
        if len(data) < 100 or page >= 10:
            break
        page += 1

    for rule in rules:
        params = rule.get("parameters") or {}
        if rule.get("type") == "required_status_checks":
            for c in params.get("required_status_checks") or []:
                ctx = c.get("context")
                if ctx and ctx not in out["required"]:
                    out["required"].append(ctx)
        elif rule.get("type") == "pull_request":
            n = params.get("required_approving_review_count") or 0
            if n > (out["approvals"] or 0):
                out["approvals"] = n
            if n > 0 and rule.get("ruleset_id") not in out["ruleset_ids"]:
                out["ruleset_ids"].append(rule.get("ruleset_id"))
            out["source"] = "ruleset"

    if not rules:
        data, err = client.get("repos/%s/branches/%s/protection" % (repo, esc))
        code = getattr(err, "code", None)
        if isinstance(data, dict):
            rsc = data.get("required_status_checks") or {}
            ctxs = [c.get("context") for c in rsc.get("checks") or []] + list(rsc.get("contexts") or [])
            out["required"] = sorted({c for c in ctxs if c})
            reviews = data.get("required_pull_request_reviews")
            if reviews is not None:
                out["approvals"] = reviews.get("required_approving_review_count") or 0
                out["source"] = "classic"
        elif code == 404:
            pass  # no classic protection: an answer, not an error
        else:
            # 403 = this token is not allowed to look. That is "unknown", not "none".
            out["approvals"] = None
            out["errors"].append("classic protection unreadable (%s)" % _why(err))
    return out


# ------------------------------------------------------------------ pull requests
PR_FIELDS = """
  number title url createdAt isDraft mergeable mergeStateStatus reviewDecision
  author { login } repository { name } baseRefName headRefOid
  autoMergeRequest { enabledAt }
"""

SEARCH = """
query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 100, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest { %s } }
  }
}""" % PR_FIELDS

ONE_PR = """
query($o: String!, $r: String!, $n: Int!) {
  repository(owner: $o, name: $r) { pullRequest(number: $n) { %s } }
}""" % PR_FIELDS

ROLLUP = """
query($o: String!, $r: String!, $n: Int!) {
  repository(owner: $o, name: $r) { pullRequest(number: $n) {
    commits(last: 1) { nodes { commit { oid statusCheckRollup { contexts(first: 100) { nodes {
      __typename
      ... on CheckRun { name status conclusion }
      ... on StatusContext { context state }
    } } } } } }
  } }
}"""


def search_open_prs(gql, owner):
    """Every open pull request in the owner's non-archived repos, in one or two calls.

    Returns (prs, error). `prs` is None when the search itself failed — which must read as
    "not checked", because an empty list reads as "no open loops", the good news.
    """
    q = "is:pr is:open user:%s archived:false" % owner
    prs, after = [], None
    for _ in range(10):
        data, errors, exc = gql.query(SEARCH, {"q": q, "after": after})
        if not data or not data.get("search"):
            why = _why(exc) if exc else "; ".join(e.get("message", "?") for e in errors[:2]) or "no data"
            return None, "open pull requests unreadable (%s)" % why
        s = data["search"]
        prs.extend(n for n in s.get("nodes") or [] if n and n.get("number"))
        if not s.get("pageInfo", {}).get("hasNextPage"):
            break
        after = s["pageInfo"]["endCursor"]
    return prs, None


def refresh_unknown(gql, owner, prs):
    """GitHub works mergeability out lazily: the first question starts the computation and
    answers UNKNOWN. Asking again a few seconds later usually gets the real answer. Only the
    PRs that came back UNKNOWN are asked twice; a second UNKNOWN is reported as unknown."""
    stale = [p for p in prs if p.get("mergeStateStatus") == "UNKNOWN" or p.get("mergeable") == "UNKNOWN"]
    if not stale:
        return
    time.sleep(4)
    for p in stale:
        data, _errors, _exc = gql.query(ONE_PR, {"o": owner, "r": p["repository"]["name"], "n": p["number"]})
        fresh = ((data or {}).get("repository") or {}).get("pullRequest")
        if fresh:
            p.update(fresh)


# ------------------------------------------------------------------ checks
def evaluate_checks(required, contexts, complete):
    """Which required checks failed, are pending, never reported, or could not be read.

    `contexts` is a list of (name, state) with state one of GitHub's check conclusions or
    status states, or IN_PROGRESS/QUEUED/PENDING/EXPECTED for unfinished ones. `complete`
    says whether EVERY kind of check could be read: when it is False a required name that
    never appears is "unread", not "missing", because it may be exactly the kind this
    token cannot see (a Vercel commit status, say).

    Pure, so the fixtures can pin it.
    """
    out = {"required": list(required), "failing": [], "pending": [], "missing": [],
           "unread": [], "passed": []}
    for req in required:
        states = [s for n, s in contexts if n == req]
        if not states:
            (out["missing"] if complete else out["unread"]).append(req)
        elif any(s in FAILED for s in states):
            out["failing"].append(req)
        elif all(s in PASSED for s in states):
            out["passed"].append(req)
        else:
            out["pending"].append(req)
    return out


def read_checks(client, gql, owner, repo, number, head_sha, required, use_actions=True):
    """The PR's required checks, read the best way this token allows.

    1. GraphQL `statusCheckRollup` — every check run and commit status on the head commit.
       Works with an ordinary `gh` login. A fine-grained token gets an error for the check
       runs (see the module docstring), and then:
    2. the Actions API — each workflow run on the head commit and its jobs, whose names
       are the check names — plus the commit-status API for the rest. Either half can be
       refused independently; a required check that neither half could see is "unread".
    """
    if not required:
        return dict(evaluate_checks([], [], True), source="none-required")

    data, errors, exc = gql.query(ROLLUP, {"o": owner, "r": repo, "n": number})
    nodes = None
    if data and not errors:
        pr = ((data.get("repository") or {}).get("pullRequest") or {})
        commits = ((pr.get("commits") or {}).get("nodes") or [])
        if commits:
            rollup = (commits[0].get("commit") or {}).get("statusCheckRollup")
            nodes = ((rollup or {}).get("contexts") or {}).get("nodes") or []
    if nodes is not None:
        ctx = []
        for n in nodes:
            if n.get("__typename") == "CheckRun":
                state = n.get("conclusion") if n.get("status") == "COMPLETED" else (n.get("status") or "PENDING")
                ctx.append((n.get("name"), state or "PENDING"))
            elif n.get("__typename") == "StatusContext":
                ctx.append((n.get("context"), n.get("state") or "PENDING"))
        return dict(evaluate_checks(required, ctx, True), source="rollup")

    if not use_actions or not head_sha:
        return dict(evaluate_checks(required, [], False), source="unread")

    full = "%s/%s" % (owner, repo)
    ctx, complete = [], True
    runs, err = client.get("repos/%s/actions/runs?head_sha=%s&per_page=100" % (full, head_sha))
    if isinstance(runs, dict):
        # Newest run first, so a re-run's result is the one that counts for a job name.
        latest = {}
        for run in sorted(runs.get("workflow_runs") or [], key=lambda r: r.get("id") or 0, reverse=True):
            jobs, jerr = client.get("repos/%s/actions/runs/%d/jobs?per_page=100" % (full, run["id"]))
            if not isinstance(jobs, dict):
                complete = False
                continue
            for job in jobs.get("jobs") or []:
                name = job.get("name")
                if not name or name in latest:
                    continue
                if job.get("status") == "completed":
                    latest[name] = (job.get("conclusion") or "").upper() or "PENDING"
                else:
                    latest[name] = (job.get("status") or "PENDING").upper()
        ctx.extend(latest.items())
    else:
        complete = False
    statuses, serr = client.get("repos/%s/commits/%s/status" % (full, head_sha))
    if isinstance(statuses, dict):
        for s in statuses.get("statuses") or []:
            ctx.append((s.get("context"), (s.get("state") or "pending").upper()))
    else:
        complete = False
    source = "actions" if complete else "partial"
    return dict(evaluate_checks(required, ctx, complete), source=source)


# ------------------------------------------------------------------ security fixes
def read_security(client, repo, today, silent_days, use_actions=True):
    """Are Dependabot security fixes on here, and are they actually running?

    Three reads, each only when the one before says it matters: the switch, then the open
    alerts, then Dependabot's own runs. Every field is None when it could not be read.
    """
    out = {"fixes_on": None, "alerts": None, "fixable": None, "fixable_runtime": None,
           "critical": None, "high": None, "oldest_fixable": None,
           "last_run": None, "runs_recent": None, "errors": []}
    data, err = client.get("repos/%s/automated-security-fixes" % repo)
    if isinstance(data, dict):
        out["fixes_on"] = bool(data.get("enabled")) and not data.get("paused")
    elif getattr(err, "code", None) == 404:
        out["fixes_on"] = False
    else:
        out["errors"].append("security-fix switch unreadable (%s)" % _why(err))
        return out
    if not out["fixes_on"]:
        return out

    # Cursor pagination only: this endpoint answers HTTP 400 to a `page=` parameter (found
    # on the first live run, 2026-09-22), so the next page is whatever the Link header says.
    alerts, url = [], "repos/%s/dependabot/alerts?state=open&per_page=100" % repo
    for _ in range(10):
        # `get` returns (data, headers) on success and (None, the error) on failure.
        data, meta = client.get(url)
        if not isinstance(data, list):
            # Security fixes cannot be on while alerts are off, so a refusal here is this
            # token not being allowed to look ("Dependabot alerts: read" is not among the
            # weekly token's permissions as of 2026-09-22) — unread, never "no alerts".
            out["errors"].append("security alerts unreadable (%s)" % _why(meta))
            return out
        alerts.extend(data)
        url = _next_link(meta)
        if not url:
            break
    fixable = [a for a in alerts
               if ((a.get("security_vulnerability") or {}).get("first_patched_version") or {}).get("identifier")]
    out["alerts"] = len(alerts)
    out["fixable"] = len(fixable)
    out["fixable_runtime"] = sum(1 for a in fixable if (a.get("dependency") or {}).get("scope") == "runtime")
    sev = [((a.get("security_advisory") or {}).get("severity") or "").lower() for a in fixable]
    out["critical"] = sev.count("critical")
    out["high"] = sev.count("high")
    created = sorted(a.get("created_at") for a in fixable if a.get("created_at"))
    out["oldest_fixable"] = created[0][:10] if created else None
    if not fixable or not use_actions:
        return out

    data, err = client.get("repos/%s/actions/runs?event=dynamic&per_page=100" % repo)
    if not isinstance(data, dict):
        out["errors"].append("Dependabot runs unreadable (%s)" % _why(err))
        return out
    mine = [r for r in data.get("workflow_runs") or [] if scan._is_free_dependabot_run(r)]
    dates = sorted((r.get("created_at") or "")[:10] for r in mine if r.get("created_at"))
    out["last_run"] = dates[-1] if dates else None
    cutoff = (today - dt.timedelta(days=silent_days)).isoformat()
    out["runs_recent"] = sum(1 for d in dates if d >= cutoff)
    return out


# ------------------------------------------------------------------ the derivation
def pr_state(pr, checks):
    """The ONE reason a pull request is not merging, most fundamental first. Pure."""
    if pr.get("isDraft"):
        return "draft"
    if pr.get("mergeable") == "CONFLICTING" or pr.get("mergeStateStatus") == "DIRTY":
        return "conflicting"
    if checks and checks.get("failing"):
        return "checks-failing"
    rd = pr.get("reviewDecision")
    if rd == "CHANGES_REQUESTED":
        return "changes-requested"
    if rd == "REVIEW_REQUIRED":
        return "review-required"
    if checks and checks.get("pending"):
        return "checks-pending"
    if checks and checks.get("missing"):
        return "check-missing"
    mss = pr.get("mergeStateStatus")
    if mss == "BEHIND":
        return "behind"
    if mss in ("CLEAN", "HAS_HOOKS", "UNSTABLE"):
        return "ready"
    if mss == "BLOCKED":
        if checks is None or checks.get("unread"):
            return "blocked-unread"
        return "blocked"
    return "unknown"


def is_bot(pr):
    return ((pr.get("author") or {}).get("login") or "") in ("dependabot", "dependabot[bot]", "app/dependabot")


def derive_loops(facts, stale_days=STALE_DAYS):
    """Facts in, open loops out. Pure: no clock, no network, so the fixtures can pin it.

    Ordering is oldest first. Repo-level loops (a rule, a security switch) carry the age of
    the oldest thing they are holding up: the oldest pull request stranded behind the review
    rule, the oldest fixable alert behind the silent security fixes.
    """
    today = dt.date.fromisoformat(facts["today"])
    repos = facts.get("repos") or {}
    checks = facts.get("checks") or {}
    loops = []
    measured = {"prs": facts.get("prs") is not None,
                "checks_unread": [], "rules_unread": [], "security_unread": [],
                "skipped": facts.get("skipped") or []}

    open_bot = {}
    for pr in facts.get("prs") or []:
        name = pr["repository"]["name"]
        if is_bot(pr):
            open_bot[name] = open_bot.get(name, 0) + 1
        age = _days(pr.get("createdAt"), today)
        queued = bool(pr.get("autoMergeRequest"))
        key = "%s#%d" % (name, pr["number"])
        chk = checks.get(key)
        stale = age is not None and age > stale_days
        # A queued Dependabot update is a candidate at ANY age: GitHub holds a red one
        # forever and says nothing.
        if not stale and not (is_bot(pr) and queued):
            continue
        state = pr_state(pr, chk)
        if chk and chk.get("unread") and (stale or queued):
            measured["checks_unread"].append(key)
        if not stale and state != "checks-failing":
            continue  # a queued update that is merely waiting is not a loop yet
        loops.append({"kind": "pr", "repo": name, "number": pr["number"], "url": pr.get("url"),
                      "title": pr.get("title"), "bot": is_bot(pr), "queued": queued,
                      "age_days": age, "state": state,
                      "failing": (chk or {}).get("failing") or []})

    stranded = {}
    for lp in loops:
        if lp["state"] == "review-required":
            stranded.setdefault(lp["repo"], []).append(lp)

    for name in sorted(repos):
        r = repos[name]
        rules = r.get("rules")
        if rules is not None:
            if rules.get("approvals") is None:
                measured["rules_unread"].append(name)
            elif rules["approvals"] > 0:
                held = stranded.get(name, [])
                loops.append({"kind": "approvals", "repo": name, "approvals": rules["approvals"],
                              "source": rules.get("source"),
                              "stranded": [lp["number"] for lp in held],
                              "age_days": max([lp["age_days"] or 0 for lp in held] or [0])})
        sec = r.get("security")
        if sec is None:
            continue
        if sec.get("errors"):
            measured["security_unread"].append(name)
            continue
        if not (sec.get("fixes_on") and (sec.get("fixable") or 0) > 0):
            continue
        # Both halves of "nothing is fixing these" have to have been READ: the run count
        # (absent under --skip-actions) and the open pull requests (absent when the search
        # failed). A recent run settles it on its own; otherwise a missing half makes this
        # repo unknown, not quiet.
        if sec.get("runs_recent") is None:
            measured["security_unread"].append(name)
            continue
        if sec["runs_recent"] > 0:
            continue
        if not measured["prs"]:
            measured["security_unread"].append(name)
            continue
        if not open_bot.get(name):
            loops.append({"kind": "silent-security", "repo": name,
                          "fixable": sec["fixable"], "fixable_runtime": sec.get("fixable_runtime"),
                          "critical": sec.get("critical"), "high": sec.get("high"),
                          "last_run": sec.get("last_run"),
                          "age_days": _days(sec.get("oldest_fixable"), today) or 0})

    loops.sort(key=lambda x: (-(x.get("age_days") or 0), x["repo"], x.get("number") or 0))
    return loops, measured


# ------------------------------------------------------------------ the scan
def gather(client, gql, owner, repos, today, stale_days, silent_days, use_actions, workers,
           progress=False):
    facts = {"owner": owner, "today": today.isoformat(), "stale_days": stale_days,
             "silent_days": silent_days, "repos": {}, "checks": {}, "errors": [],
             "skipped": [] if use_actions else ["actions"]}

    prs, err = search_open_prs(gql, owner)
    if err:
        facts["errors"].append(err)
    facts["prs"] = prs
    if prs:
        # Only the pull requests in this owner's non-archived repo list: search can return
        # a PR in an archived repo for a few minutes after archiving, and the rest of the
        # audit would not recognise that repo.
        known = {r[0] for r in repos}
        prs[:] = [p for p in prs if p["repository"]["name"] in known]
        refresh_unknown(gql, owner, prs)

    def per_repo(entry):
        name, branch, _vis, _fork = entry
        full = "%s/%s" % (owner, name)
        return name, {"rules": read_rules(client, full, branch),
                      "security": read_security(client, full, today, silent_days, use_actions)}

    with futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for fut in futures.as_completed([pool.submit(per_repo, e) for e in repos]):
            try:
                name, got = fut.result()
                facts["repos"][name] = got
            except Exception as exc:  # one repo's failure is that repo's unknown
                facts["errors"].append("repo scan failed: %s" % exc)
            if progress:
                sys.stderr.write(".")
                sys.stderr.flush()

    # Checks only for the pull requests that could become loops: stale ones, and queued
    # Dependabot updates of any age.
    wanted = []
    for pr in prs or []:
        age = _days(pr.get("createdAt"), today)
        if (age is not None and age > stale_days) or (is_bot(pr) and pr.get("autoMergeRequest")):
            wanted.append(pr)

    def per_pr(pr):
        name = pr["repository"]["name"]
        rules = (facts["repos"].get(name) or {}).get("rules") or {}
        if not rules.get("read", False):
            return "%s#%d" % (name, pr["number"]), dict(evaluate_checks([], [], False),
                                                       source="rules-unread", unread=["(rules)"])
        return "%s#%d" % (name, pr["number"]), read_checks(
            client, gql, owner, name, pr["number"], pr.get("headRefOid"),
            rules.get("required") or [], use_actions)

    with futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for fut in futures.as_completed([pool.submit(per_pr, p) for p in wanted]):
            try:
                key, got = fut.result()
                facts["checks"][key] = got
            except Exception as exc:
                facts["errors"].append("check read failed: %s" % exc)
    if client.exhausted:
        facts["errors"].append("hourly GitHub API budget exhausted mid-run; open loops are incomplete")
    return facts


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--owner", required=True)
    ap.add_argument("--stale-days", type=int, default=STALE_DAYS)
    ap.add_argument("--silent-days", type=int, default=SILENT_DAYS)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--no-actions", action="store_true",
                    help="make no Actions API calls (bin/audit --skip-actions): the check "
                         "fallback and the Dependabot-run count then read as not measured")
    ap.add_argument("--progress", action="store_true")
    ap.add_argument("--derive", metavar="FACTS_JSON",
                    help="skip the network: derive loops from a saved facts file (fixtures)")
    args = ap.parse_args()

    if args.derive:
        with open(args.derive) as fh:
            facts = json.load(fh)
    else:
        token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        if not token:
            try:
                token = subprocess.run(["gh", "auth", "token"], capture_output=True,
                                       text=True, check=True).stdout.strip()
            except Exception as exc:
                print("loops-scan: no GitHub token (%s)" % exc, file=sys.stderr)
                sys.exit(1)
        repos = []
        for line in sys.stdin.read().splitlines():
            if not line.strip():
                continue
            parts = line.split("\t") + ["", "", ""]
            repos.append((parts[0], parts[1] or "main", parts[2] or "PUBLIC", parts[3] == "true"))
        facts = gather(scan.Client(token), Gql(token), args.owner, repos,
                       dt.datetime.now(dt.timezone.utc).date(), args.stale_days,
                       args.silent_days, not args.no_actions, args.workers, args.progress)
        if args.progress:
            sys.stderr.write("\n")

    loops, measured = derive_loops(facts, facts.get("stale_days", args.stale_days))
    json.dump({"facts": facts, "loops": loops, "measured": measured,
               "stale_days": facts.get("stale_days", args.stale_days),
               "silent_days": facts.get("silent_days", args.silent_days),
               "errors": facts.get("errors") or []},
              sys.stdout, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
