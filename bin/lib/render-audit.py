#!/usr/bin/env python3
"""Render `bin/audit`'s rows three ways: the table, `--json`, and `--digest`.

Reads one JSON object per line on stdin (one repo each) and writes the chosen form.

    render-audit.py --mode table|json|digest --owner khglynn --since 2026-09-01 --cap 300

WHY THE RENDERING LIVES HERE AND NOT IN THE BASH
The digest is the only part of this system Kevin actually reads every week, and its whole
job is to be understandable at a glance by someone who does not know what a runner or a
lockfile is. Wording that matters that much wants to sit in one place where it can be read
end-to-end, not assembled from `echo` lines scattered through a loop.

THE PRIVATE-MINUTES ARITHMETIC
Public repositories cost nothing, so they are shown and excluded from the total. The
allowance is 3,000 minutes a month. Projection is deliberately the simplest possible:
current usage divided by days elapsed, times days in the month. It assumes the rest of
the month looks like the start of it, which is wrong in both directions — but a projection
you can do in your head is one you can sanity-check, and this one is only ever used to
answer "is this about to become a problem". Written 2026-09-14.
"""
import argparse
import calendar
import datetime as dt
import json
import sys

ALLOWANCE = 3000  # private-repo Actions minutes per month on this plan


def load(stream):
    rows = []
    for line in stream:
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    return rows


def counts(rows):
    c = {"total": len(rows), "enrolled": 0, "security_only": 0,
         "forks": 0, "drifting": 0, "unreadable": 0}
    for r in rows:
        s = r["status"]
        if s.startswith("enrolled"):
            c["enrolled"] += 1
        elif s.startswith("security-only"):
            c["security_only"] += 1
        elif s.startswith("fork"):
            c["forks"] += 1
        elif s.startswith("unknown"):
            c["unreadable"] += 1
        else:
            c["drifting"] += 1
    return c


def minutes_picture(rows, since):
    start = dt.date.fromisoformat(since)
    today = dt.date.today()
    days_in_month = calendar.monthrange(start.year, start.month)[1]
    now = dt.datetime.now(dt.timezone.utc)
    elapsed = (now - dt.datetime(start.year, start.month, start.day,
                                 tzinfo=dt.timezone.utc)).total_seconds() / 86400.0
    elapsed = max(elapsed, 0.5)

    private = sum(r.get("minutes") or 0 for r in rows if r.get("visibility") == "PRIVATE")
    public = sum(r.get("minutes") or 0 for r in rows if r.get("visibility") != "PRIVATE")
    daily = private / elapsed
    projected = daily * days_in_month
    runout = None
    if daily > 0 and projected > ALLOWANCE:
        day_offset = ALLOWANCE / daily
        runout = dt.datetime(start.year, start.month, start.day) + dt.timedelta(days=day_offset)
    capped = [r["name"] for r in rows if r.get("capped")]
    nonlinux = sorted({x for r in rows for x in (r.get("runners") or []) if x != "UBUNTU"})
    return {"private": private, "public": public, "daily": daily,
            "projected": int(round(projected)), "runout": runout,
            "days_in_month": days_in_month, "elapsed": elapsed,
            "capped": capped, "nonlinux": nonlinux, "today": today}


def warn_lines(rows):
    missing = [(r["name"], r["missing_timeout"]) for r in rows if r.get("missing_timeout")]
    double = [(r["name"], r["double_trigger"]) for r in rows if r.get("double_trigger")]
    unparsed = [(r["name"], r["unparsed"]) for r in rows if r.get("unparsed")]
    return missing, double, unparsed


# ------------------------------------------------------------------ the table
def render_table(rows, owner, since, cap, out, method="jobs", note=""):
    c = counts(rows)
    m = minutes_picture(rows, since)
    print("# Repo standards audit — %s" % m["today"].isoformat(), file=out)
    print(file=out)
    summary = ("%d active repos under `%s`: **%d enrolled**, %d security-only, "
               "%d forks, **%d drifting**" % (c["total"], owner, c["enrolled"],
                                              c["security_only"], c["forks"], c["drifting"]))
    if c["unreadable"]:
        summary += ", **%d unreadable**" % c["unreadable"]
    print(summary + ".", file=out)
    print(file=out)
    print("| repo | vis | last push | manifest | dependabot.yml | stub | auto-merge | "
          "approve | required checks | open bot PRs | mins (est) | status |", file=out)
    print("|---|---|---|---|---|---|---|---|---|---|---|---|", file=out)
    for r in rows:
        mins = "—" if r.get("minutes") is None else str(r["minutes"])
        if r.get("minutes"):
            if r.get("visibility") != "PRIVATE":
                mins += " (public, free)"
            if r.get("capped"):
                mins += " ⚠ capped"
        print("| `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |"
              % (r["name"], r["visibility"], r["pushed"], r["manifest"], r["dependabot"],
                 r["stub"], r["auto_merge"], r.get("approve_cell", "?"), r["checks"],
                 r["prs"], mins, r["status"]), file=out)
    print(file=out)

    print("**Actions minutes this billing month (since %s) — an ESTIMATE, not a bill.**" % since,
          file=out)
    print("Private repos: **%d of %d** free minutes. At %.0f/day the month projects to "
          "**%d**%s." % (m["private"], ALLOWANCE, m["daily"], m["projected"],
                         (", exhausting the pool around **%s**" % m["runout"].strftime("%-d %b"))
                         if m["runout"] else ", inside the pool"), file=out)
    print("Public repos: %d minutes, free and not counted." % m["public"], file=out)
    if note:
        print("⚠ %s." % note, file=out)
    if method == "timing":
        print("⚠ Measured the cheap way (wall-clock per run), which reads about 15%% low.", file=out)
    if m["capped"]:
        print("⚠ Run cap of %d hit in: %s — those repos' minutes are LOW by however much "
              "the untimed runs cost." % (cap, ", ".join("`%s`" % x for x in m["capped"])), file=out)
    if m["nonlinux"]:
        print("Note: non-Linux runners seen (%s); their 2x (Windows) / 10x (macOS) multipliers "
              "are applied. Larger runners bill per-minute rates this cannot see."
              % ", ".join(m["nonlinux"]), file=out)
    print("_Rebuilt from each job's start and finish, rounded up to the minute the way GitHub "
          "bills, times the runner multiplier. The billing endpoints would settle it but need "
          "token scopes this token does not have and should not be given for a read-only "
          "monitor, so nothing here reads them._", file=out)
    print(file=out)

    missing, double, unparsed = warn_lines(rows)
    if missing or double or unparsed:
        print("**Warnings — not drift, nothing is broken, but each one costs minutes.**", file=out)
        for name, pairs in missing:
            print("- `%s`: no time limit on %s. A hang there inherits GitHub's six-hour "
                  "default." % (name, ", ".join("`%s`" % p for p in pairs)), file=out)
        for name, wfs in double:
            print("- `%s`: %s runs on both a branch push and the pull request, so every "
                  "commit on a PR branch runs it twice. Sometimes deliberate."
                  % (name, ", ".join("`%s`" % w for w in wfs)), file=out)
        for name, wfs in unparsed:
            print("- `%s`: could not read %s, so it was not checked (unknown, not clean)."
                  % (name, ", ".join("`%s`" % w for w in wfs)), file=out)
        print(file=out)

    errs = [(r["name"], r["errors"]) for r in rows if r.get("errors")]
    if errs:
        print("**Could not read:**", file=out)
        for name, e in errs:
            print("- `%s`: %s" % (name, "; ".join(e)), file=out)
        print(file=out)

    print("_`manifest` counts GitHub Actions workflows as well as app dependency files — an action_",
          file=out)
    print("_is a dependency that runs with the repo's token, and nobody updates those by hand._",
          file=out)
    print(file=out)
    print("_`approve` is the repo switch \"Allow GitHub Actions to create and approve pull "
          "requests\"._", file=out)
    print("_With it off, the shared workflow's approval is refused and every update PR queues "
          "forever._", file=out)
    print(file=out)
    print("_Security alerts and security update PRs are on account-wide and need no file, so_",
          file=out)
    print("_`security-only` means \"protected against known vulnerabilities, not kept current\"._",
          file=out)
    print("_To move a repo from security-only to enrolled: `bin/enroll %s/<name> --ci-check "
          "<check>`._" % owner, file=out)


# ------------------------------------------------------------------ the digest
def _plural(n, one, many=None):
    return one if n == 1 else (many or one + "s")


def render_digest(rows, owner, since, cap, out, method="jobs", note=""):
    c = counts(rows)
    m = minutes_picture(rows, since)
    total_prs = sum(r.get("pr_count") or 0 for r in rows)
    ages = [r.get("pr_oldest_days") for r in rows if r.get("pr_oldest_days") is not None]
    oldest = max(ages) if ages else None

    # ---- headline: what a person needs to know before deciding to read further.
    head = ["*Dependency check — %s*" % m["today"].strftime("%-d %b %Y"), ""]
    line = "%d of %d repos keep themselves up to date" % (c["enrolled"], c["total"])
    if c["drifting"]:
        line += "; %d %s half set up" % (c["drifting"], _plural(c["drifting"], "is", "are"))
    line += "."
    if total_prs and oldest is not None:
        line += (" %d update %s waiting, the oldest %d %s old."
                 % (total_prs, _plural(total_prs, "pull request"), oldest,
                    _plural(oldest, "day")))
    elif total_prs:
        line += " %d update %s waiting." % (total_prs, _plural(total_prs, "pull request"))
    else:
        line += " No update pull requests are waiting."
    head.append(line)

    budget = ("Build time on the private repos this month: about %d minutes of the free "
              "3,000 (an estimate)." % m["private"])
    if m["runout"]:
        budget += (" At this rate the free minutes run out around %s."
                   % m["runout"].strftime("%-d %b"))
    else:
        budget += (" At this rate the month ends near %d, inside the free pool."
                   % m["projected"])
    head.append(budget)

    # ---- one line per repo that needs something
    # Repos that could not be read are collapsed into a single line once there are more
    # than a couple: forty identical "could not read" lines is not a Slack message, and
    # when the cause is one shared thing (an exhausted API budget) forty lines say
    # exactly as much as one does.
    unknown = [r for r in rows if r["status"].startswith("unknown")]
    collapse_unknown = len(unknown) > 2
    body = []
    for r in sorted(rows, key=lambda x: (-(x.get("pr_count") or 0), x["name"])):
        drift = r["status"].startswith("drift") or r["status"].startswith("unknown")
        if collapse_unknown and r["status"].startswith("unknown") and not r.get("pr_count"):
            continue
        if not drift and not r.get("pr_count"):
            continue
        bits = []
        if r.get("pr_count"):
            bits.append("%d update %s waiting, oldest %d %s"
                        % (r["pr_count"], _plural(r["pr_count"], "pull request"),
                           r["pr_oldest_days"], _plural(r["pr_oldest_days"], "day")))
        if drift and not (collapse_unknown and r["status"].startswith("unknown")):
            bits.append(r["status"].split(":", 1)[-1].strip()
                        if ":" in r["status"] else r["status"])
        body.append("- %s — %s." % (r["name"], "; ".join(bits)))
    if collapse_unknown:
        body.append("- %d repos could not be read this week, so nothing is known about "
                    "them — that is usually a GitHub rate limit, not a problem with the "
                    "repos." % len(unknown))

    # ---- one trailing warning line, only when there is something in it
    missing, double, unparsed = warn_lines(rows)
    tail = []
    if missing:
        jobs = sum(len(p) for _, p in missing)
        tail.append("Also: %d build %s across %d %s have no time limit, so one stuck job "
                    "could burn six hours of the free pool."
                    % (jobs, _plural(jobs, "job"), len(missing), _plural(len(missing), "repo")))
    if double:
        n = len(double)
        tail.append("Also: %d %s %s tests twice for every change (once for the branch, once "
                    "for the pull request), which may be on purpose."
                    % (n, _plural(n, "repo"),
                       "runs its" if n == 1 else "run their"))
    if m["capped"]:
        tail.append("Note: %s had more runs this month than were measured, so the minutes "
                    "above are low." % ", ".join(m["capped"]))
    if method == "timing" or note:
        tail.append("Note: the build-time figure was measured the quick way this week and "
                    "reads low.")

    # ---- the one thing worth doing
    act = None
    drifters = [r for r in rows if r["status"].startswith("drift")]
    if drifters:
        d = drifters[0]
        act = ("To act: %s is half set up — %s." % (d["name"], d["status"].split(":", 1)[-1].strip()))
    elif total_prs and oldest is not None:
        who = sorted([r for r in rows if r.get("pr_count")],
                     key=lambda x: -(x.get("pr_oldest_days") or 0))[0]
        act = ("To act: the oldest waiting update is in %s, %d %s old — open it and merge or "
               "close it." % (who["name"], who["pr_oldest_days"],
                              _plural(who["pr_oldest_days"], "day")))
    else:
        act = "To act: nothing. Everything enrolled is current."

    for part in (head, body, tail, [act]):
        if not part:
            continue
        for ln in part:
            print(ln, file=out)
        print(file=out)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mode", choices=["table", "json", "digest"], default="table")
    ap.add_argument("--owner", default="khglynn")
    ap.add_argument("--since", required=True)
    ap.add_argument("--cap", type=int, default=300)
    ap.add_argument("--method", default="jobs",
                    help="how minutes were measured: jobs | timing | none")
    ap.add_argument("--note", default="", help="a caveat to print alongside the minutes")
    args = ap.parse_args()

    rows = load(sys.stdin)
    if args.mode == "json":
        json.dump({"generated": dt.datetime.now(dt.timezone.utc)
                   .strftime("%Y-%m-%dT%H:%M:%SZ"),
                   "owner": args.owner, "since": args.since, "run_cap": args.cap,
                   "allowance_minutes": ALLOWANCE,
                   "summary": counts(rows),
                   "minutes_method": args.method,
                   "minutes_note": args.note or None,
                   "minutes": {k: (v.isoformat() if hasattr(v, "isoformat") else v)
                               for k, v in minutes_picture(rows, args.since).items()},
                   "repos": rows}, sys.stdout, indent=2, sort_keys=True)
        print()
    elif args.mode == "digest":
        render_digest(rows, args.owner, args.since, args.cap, sys.stdout,
                      args.method, args.note)
    else:
        render_table(rows, args.owner, args.since, args.cap, sys.stdout,
                     args.method, args.note)


if __name__ == "__main__":
    main()
