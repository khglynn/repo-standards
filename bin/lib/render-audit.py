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
BODY_LINES = 5    # most repo lines the digest may print before collapsing the rest
WORD_CAP = 150    # …and the whole message's ceiling, which the repo list gives way to


def load(stream):
    rows = []
    for line in stream:
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    return rows


def counts(rows):
    """How many repos are in each state — and, inside "enrolled", how many of those are
    the security-fixes-only shape.

    WHY THAT ONE IS COUNTED AS ENROLLED (2026-09-14). `bin/enroll --security-only` writes
    the merge rules and deliberately no `dependabot.yml`, so the repo takes GitHub's
    account-wide security fixes, merges them behind its required check, and gets no routine
    version bumps. Filing that under `security-only` would put a repo whose security fixes
    merge themselves in the same bucket as one where nothing merges at all, which is the
    more misleading of the two errors — the repo IS handled.

    So it counts as enrolled and the headline says the parenthetical out loud, because
    "keeps itself up to date" on its own overstates what a security-only repo does. The
    count is carried separately rather than re-derived from the strings downstream: one
    place decides what the word means.
    """
    c = {"total": len(rows), "enrolled": 0, "enrolled_security_only": 0,
         "security_only": 0, "forks": 0, "drifting": 0, "unreadable": 0}
    for r in rows:
        s = r["status"]
        if s.startswith("enrolled"):
            c["enrolled"] += 1
            if "security fixes only" in s:
                c["enrolled_security_only"] += 1
        elif s.startswith("security-only"):
            c["security_only"] += 1
        elif s.startswith("fork"):
            c["forks"] += 1
        elif s.startswith("unknown"):
            c["unreadable"] += 1
        else:
            c["drifting"] += 1
    return c


# `method` says how (or whether) the minutes were measured this run:
#   jobs    — GitHub's per-job billing rule rebuilt from each job's start and finish
#   timing  — the cheap wall-clock fallback, which reads about 15% low
#   skipped — `--skip-actions`: no Actions calls were made at all
#   none    — the Actions scan was attempted and returned nothing
UNMEASURED = ("skipped", "none")


def minutes_picture(rows, since, method="jobs", today=None):
    """The month's build-time picture, or an explicit "not measured" when there isn't one.

    THE ZERO THAT WAS A LIE. This used to sum `minutes` across every row and hand back a
    number no matter what — so `bin/audit --digest --skip-actions`, which makes no Actions
    calls at all, printed "about 0 minutes of the free 3,000 … the month ends near 0,
    inside the free pool" about a measurement it had never taken (found 2026-09-14 06:55).
    That is the same shape as the two bugs above it: a confident sentence standing in for
    an absent fact, in the one output a person reads without checking. A skipped or failed
    measurement has to read as NOT MEASURED — never as zero, and never with a projection
    attached, because a projection is a claim about a number that does not exist.

    So `measured` is the first thing every caller asks, and when it is False there is no
    figure to print: `private`, `public`, `daily` and `projected` are all None rather than
    zeroes that format perfectly well.

    AND `method` ALONE IS NOT ENOUGH TO ASK IT. The first version keyed `measured` on the
    method, which left two other doors open to exactly the same confident zero, both found
    by review on 2026-09-14 and both reproduced with this renderer:

      * no private repo was visible at all (a repo-scoped token in a cloud routine sees
        none of them) — `private` sums to 0 over an empty list and the sentence reads
        "about 0 minutes of the free 3,000 … inside the free pool";
      * every private repo's Actions scan failed — same sentence, followed by a
        contradicting "4 of the 4 repos could not be measured" underneath it.

    So the question is asked of the DATA: were any private repos measured, and did any
    repo with billable builds actually get one of them timed. A month where the private
    repos genuinely ran nothing billable stays a real zero — that is a measurement, not an
    absence — and an owner with no private repos at all is not "unmeasured" either.

    `today` is a parameter rather than a call to `dt.date.today()` so the fixtures can pin
    it: the projection divides by days elapsed, so a fixture tuned to pass in mid-September
    starts failing later in the month (check-audit.sh's own BIG case would have started
    failing on 27 Sep). Elapsed days are whole days, which loses the part-day the old
    version counted and therefore projects very slightly HIGH — the safe direction for a
    number whose job is to warn early.
    """
    start = dt.date.fromisoformat(since)
    today = today or dt.date.today()
    days_in_month = calendar.monthrange(start.year, start.month)[1]
    elapsed = max(float((today - start).days), 0.5)

    # A repo with no `minutes` key at all was never scanned. A repo with minutes == 0 that
    # ran nothing this month is a real zero, and the two must not be confused.
    measured_rows = [r for r in rows if r.get("minutes") is not None]
    unmeasured = [r["name"] for r in rows if r.get("minutes") is None]

    private_seen = [r for r in rows if r.get("visibility") == "PRIVATE"]
    private_rows = [r for r in measured_rows if r.get("visibility") == "PRIVATE"]
    billable = [r for r in private_rows
                if (r.get("runs") or 0) - (r.get("free_runs") or 0) > 0]
    unread = bool(billable) and not any(r.get("timed") for r in billable)

    reason = None
    if method in UNMEASURED:
        reason = method
    elif not measured_rows or (private_seen and not private_rows):
        reason = "invisible"
    elif unread:
        reason = "unread"
    measured = reason is None

    base = {"measured": measured, "method": method, "skipped": method == "skipped",
            "reason": reason, "days_in_month": days_in_month, "elapsed": elapsed,
            "today": today, "unmeasured": unmeasured}
    if not measured:
        base.update({"private": None, "public": None, "daily": None, "projected": None,
                     "runout": None, "over": False,
                     "capped": [], "nonlinux": [], "selfhosted": [], "partial": [],
                     "free_runs": 0})
        return base

    private = sum(r.get("minutes") or 0 for r in measured_rows
                  if r.get("visibility") == "PRIVATE")
    public = sum(r.get("minutes") or 0 for r in measured_rows
                 if r.get("visibility") != "PRIVATE")
    daily = private / elapsed
    projected = daily * days_in_month
    runout = None
    if daily > 0 and projected > ALLOWANCE:
        day_offset = ALLOWANCE / daily
        runout = dt.datetime(start.year, start.month, start.day) + dt.timedelta(days=day_offset)
    # A run-out date already in the past is not a forecast, and it used to print in the
    # future tense: 3,500 minutes read on 14 September announced "the free minutes run out
    # around 12 Sep". The account was at 2,515 of 3,000 that day, so this was days away.
    #
    # One line of arithmetic settles when it can happen. The projected date is
    # `start + ALLOWANCE/daily` and today is `start + elapsed`, with `daily = private /
    # elapsed`, so the date is behind today exactly when `ALLOWANCE < private` — the
    # allowance is already spent. There is therefore no case of "the date has passed but
    # the pool is not gone", and one branch covers it. Do not re-add a second one for a
    # past date; it cannot be reached, and an unreachable branch in the wording is a
    # sentence nobody will ever proof-read.
    over = private >= ALLOWANCE
    capped = [r["name"] for r in measured_rows if r.get("capped")]
    # SELF is a self-hosted runner: real minutes, billed at nothing, and nothing to do
    # with the 2x/10x multiplier note. It gets its own line rather than being filed under
    # "non-Linux".
    nonlinux = sorted({x for r in measured_rows
                       for x in (r.get("runners") or []) if x not in ("UBUNTU", "SELF")})
    selfhosted = sorted({r["name"] for r in measured_rows
                         if "SELF" in (r.get("runners") or [])})
    # A repo that ran BILLABLE builds this month but had none of them timed carries a 0
    # that is an absence, not a measurement — same trap one level down. So does one whose
    # scan logged an error. Both make the total a floor rather than a figure.
    #
    # "Billable" is load-bearing here. The first version asked `runs and not timed`, and
    # four repos whose only run this month was one of Dependabot's own free runs — timed
    # 0, correctly — were reported as unmeasurable. A run that is deliberately excluded is
    # not a run that went unread.
    partial = sorted({r["name"] for r in measured_rows
                      if r.get("errors")
                      or ((r.get("runs") or 0) - (r.get("free_runs") or 0) > 0
                          and not r.get("timed"))})
    free_runs = sum(r.get("free_runs") or 0 for r in measured_rows)
    base.update({"free_runs": free_runs})
    base.update({"private": private, "public": public, "daily": daily,
                 "projected": int(round(projected)), "runout": runout,
                 "over": over,
                 "capped": capped, "nonlinux": nonlinux, "selfhosted": selfhosted,
                 "partial": partial})
    return base


def warn_lines(rows):
    missing = [(r["name"], r["missing_timeout"]) for r in rows if r.get("missing_timeout")]
    double = [(r["name"], r["double_trigger"]) for r in rows if r.get("double_trigger")]
    unparsed = [(r["name"], r["unparsed"]) for r in rows if r.get("unparsed")]
    return missing, double, unparsed


def parsers_used(rows):
    """Which YAML reader answered the two workflow warnings, and how many repos each read.

    The brief asked for this to be said out loud, and it is not cosmetic: the regex
    fallback (the path taken on a host without PyYAML, which a cloud routine may well be)
    can answer the `timeout-minutes` half honestly and DECLINES the double-trigger
    question rather than guessing. So on that path an empty double-trigger list means
    "not checked", not "none found" — the same zero-versus-absent distinction the minutes
    figure carries, one level down.
    """
    seen = {}
    for r in rows:
        p = r.get("parser")
        if p:
            seen[p] = seen.get(p, 0) + 1
    return seen


# ------------------------------------------------------------------ the table
def render_table(rows, owner, since, cap, out, method="jobs", note="", today=None):
    c = counts(rows)
    m = minutes_picture(rows, since, method, today)
    print("# Repo standards audit — %s" % m["today"].isoformat(), file=out)
    print(file=out)
    enrolled_txt = "**%d enrolled**" % c["enrolled"]
    if c["enrolled_security_only"]:
        # Without this the count silently absorbs repos that take no routine version
        # updates at all, and the word "enrolled" quietly means two different things.
        enrolled_txt += " (%d for security fixes only)" % c["enrolled_security_only"]
    summary = ("%d active repos under `%s`: %s, %d security-only, "
               "%d forks, **%d drifting**" % (c["total"], owner, enrolled_txt,
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

    if not m["measured"]:
        # No figure, no projection, no zero. See minutes_picture's docstring.
        print("**Actions minutes this billing month — NOT MEASURED on this run.**", file=out)
        if m["reason"] == "skipped":
            print("`--skip-actions` was used, so no Actions calls were made: the `approve` "
                  "column, the minutes and both warnings below are all absent rather than "
                  "clean. Run `bin/audit` without it for the full picture.", file=out)
        elif m["reason"] == "invisible":
            print("No private repo's Actions usage could be read on this run — a token that "
                  "cannot see them produces a 0 that looks exactly like a quiet month, so "
                  "no figure is printed.", file=out)
        elif m["reason"] == "unread":
            print("Every private repo that ran billable builds this month had all of them "
                  "go unread, so the only total available is a 0 that means \"not read\".",
                  file=out)
        else:
            print("The Actions scan returned nothing, so minutes, the `approve` column and "
                  "both warnings are unknown for this run — not zero, not clean.", file=out)
        if note:
            print("⚠ %s." % note, file=out)
    else:
        print("**Actions minutes this billing month (since %s) — an ESTIMATE, not a bill.**" % since,
              file=out)
        if m["over"]:
            outlook = " — **already past the free 3,000**, so the rest of the month is billed"
        elif m["runout"]:
            outlook = ", exhausting the pool around **%s**" % m["runout"].strftime("%-d %b")
        else:
            outlook = ", inside the pool"
        print("Private repos: **%d of %d** free minutes. At %.0f/day the month projects to "
              "**%d**%s." % (m["private"], ALLOWANCE, m["daily"], m["projected"], outlook),
              file=out)
        print("Public repos: %d minutes, free and not counted." % m["public"], file=out)
        if note:
            print("⚠ %s." % note, file=out)
        if method == "timing":
            print("⚠ Measured the cheap way (wall-clock per run), which reads about 15%% low.",
                  file=out)
        if m["unmeasured"]:
            print("⚠ %d of %d repos were not measured at all (%s), so the total above is a "
                  "floor, not a figure." % (len(m["unmeasured"]), len(rows),
                                            ", ".join("`%s`" % x for x in m["unmeasured"][:6])
                                            + (" …" if len(m["unmeasured"]) > 6 else "")),
                  file=out)
        if m["partial"]:
            print("⚠ Read only partly in: %s — their minutes are LOW by whatever could not "
                  "be read." % ", ".join("`%s`" % x for x in m["partial"]), file=out)
        if m["capped"]:
            print("⚠ Run cap of %d hit in: %s — those repos' minutes are LOW by however much "
                  "the untimed runs cost." % (cap, ", ".join("`%s`" % x for x in m["capped"])),
                  file=out)
        if m["selfhosted"]:
            print("Note: self-hosted runners seen (%s); GitHub bills none of their minutes, "
                  "so they are counted as free here."
                  % ", ".join("`%s`" % x for x in m["selfhosted"]), file=out)
        if m["nonlinux"]:
            print("Note: non-Linux runners seen (%s); their 2x (Windows) / 10x (macOS) "
                  "multipliers are applied. Larger runners bill per-minute rates this cannot "
                  "see." % ", ".join(m["nonlinux"]), file=out)
        if m.get("free_runs"):
            print("Dependabot's own update runs are excluded — %d of them this month. GitHub "
                  "does not bill those on standard runners (GitHub Docs, *Dependabot on "
                  "GitHub Actions runners*, read 2026-09-14); counting them had `ynai` "
                  "reading 15 minutes when its real cost was nil."
                  % m["free_runs"], file=out)
        print("_Rebuilt from each job's start and finish, rounded up to the minute the way "
              "GitHub bills, times the runner multiplier. The billing endpoints would settle "
              "it but need token scopes this token does not have and should not be given for "
              "a read-only monitor, so nothing here reads them._", file=out)
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

    used = parsers_used(rows)
    if used.get("regex"):
        print("⚠ %d %s workflows were read with the regex fallback (PyYAML was not "
              "importable): it answers the time-limit question but DECLINES the "
              "double-trigger one, so an empty double-trigger list above means not "
              "checked, not none." % (used["regex"],
                                      "repo's" if used["regex"] == 1 else "repos'"), file=out)
        print(file=out)
    elif used.get("pyyaml"):
        print("_Workflow files parsed with PyYAML (%d %s)._"
              % (used["pyyaml"], "repo" if used["pyyaml"] == 1 else "repos"), file=out)
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
    print("_`enrolled (security fixes only)` is that plus the merge rules: no routine version_",
          file=out)
    print("_bumps arrive, and the security ones merge themselves once the required check is green._",
          file=out)
    print("_To move a repo from security-only to enrolled: `bin/enroll %s/<name> --ci-check "
          "<check>`._" % owner, file=out)


# ------------------------------------------------------------------ the digest
def _plural(n, one, many=None):
    return one if n == 1 else (many or one + "s")


def _words(parts):
    return sum(len(ln.split()) for part in parts for ln in part)


def _assemble(head, repo_lines, keep, collapsed, tail, act):
    body = list(repo_lines[:keep])
    rest = len(repo_lines) - keep
    if rest > 0:
        body.append("- and %d more %s attention."
                    % (rest, "repo needs" if rest == 1 else "repos need"))
    if collapsed:
        body.append(collapsed)
    return [head, body, tail, [act]]


def render_digest(rows, owner, since, cap, out, method="jobs", note="", today=None):
    c = counts(rows)
    m = minutes_picture(rows, since, method, today)
    total_prs = sum(r.get("pr_count") or 0 for r in rows)
    ages = [r.get("pr_oldest_days") for r in rows if r.get("pr_oldest_days") is not None]
    oldest = max(ages) if ages else None

    # ---- headline: what a person needs to know before deciding to read further.
    head = ["*Dependency check — %s*" % m["today"].strftime("%-d %b %Y"), ""]
    line = "%d of %d repos keep themselves up to date" % (c["enrolled"], c["total"])
    if c["enrolled_security_only"]:
        # Five words, and they are the difference between a true sentence and a flattering
        # one: a security-only repo merges its security fixes and takes no routine version
        # bumps at all. The headline is never trimmed by the word cap below — only the repo
        # list gives way — so this cannot quietly disappear on a busy week.
        line += " (%d for security fixes only)" % c["enrolled_security_only"]
    if c["drifting"]:
        line += "; %d %s half set up" % (c["drifting"], _plural(c["drifting"], "is", "are"))
    line += "."
    if total_prs and oldest is not None:
        line += (" %d %s waiting, the oldest %d %s old."
                 % (total_prs, _plural(total_prs, "update"), oldest,
                    _plural(oldest, "day")))
    elif total_prs:
        line += " %d %s waiting." % (total_prs, _plural(total_prs, "update"))
    else:
        line += " No updates are waiting."
    head.append(line)

    # The build-time sentence, and the one rule it lives by: it may only state a figure
    # this run actually measured. A skipped or failed measurement says so in the same
    # breath, because "about 0 minutes … inside the free pool" is what an unmeasured month
    # used to look like in Slack, and it reads exactly like good news (2026-09-14).
    if not m["measured"]:
        # Four ways not to have a figure, and the message says which. "Not checked" and
        # "checked and could not be read" want different things from Kevin: the first is
        # a flag on the run, the second is usually a token that has stopped reaching the
        # private repos.
        if m["reason"] == "invisible":
            budget = ("No private repository's build time could be read this week, so "
                      "there is no figure and no run-out date — not a zero.")
        elif m["reason"] == "unread":
            budget = ("Every private repository's builds went unread this week, so there "
                      "is no figure and no run-out date — not a zero.")
        else:
            budget = ("Build time was not checked this week, so there is no figure and no "
                      "run-out date — not a zero.")
    else:
        budget = ("Build time this month: about %d of the free 3,000 private-repo minutes "
                  "(an estimate)." % m["private"])
        # The date comes first and is never suppressed. An incomplete measurement makes the
        # figure a FLOOR, which moves the run-out date earlier, not later — so dropping the
        # date because the reading was partial withholds the more urgent version of the
        # news. Say the date, then say the figure is a floor.
        #
        # And a date in the past is not a forecast: on 2026-09-14 a projection of 12 Sep
        # printed as "the free minutes run out around 12 Sep", future tense, two days after
        # the fact. Past and over-budget each get their own sentence.
        if m["over"]:
            budget += " That is past the free 3,000, so the rest of the month is billed."
        elif m["runout"]:
            budget += (" At this rate they run out around %s."
                       % m["runout"].strftime("%-d %b"))
        else:
            budget += (" At this rate the month ends near %d, inside the free pool."
                       % m["projected"])
        short = len(m["unmeasured"]) + len(m["partial"])
        if short:
            budget += (" %d of %d %s could not be measured, so the real figure is higher "
                       "and that date could be sooner."
                       % (short, len(rows), _plural(len(rows), "repo")))
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
            # "update pull requests waiting" in full, six times under a headline that just
            # said it, is most of the reason the real message ran to 202 words against a
            # 150-word cap. The headline carries the full phrase; these lines lean on it.
            bits.append("%d waiting, oldest %d %s"
                        % (r["pr_count"], r["pr_oldest_days"],
                           _plural(r["pr_oldest_days"], "day")))
        if drift and not (collapse_unknown and r["status"].startswith("unknown")):
            bits.append(r["status"].split(":", 1)[-1].strip()
                        if ":" in r["status"] else r["status"])
        body.append("- %s — %s." % (r["name"], "; ".join(bits)))
    repo_lines = body
    collapsed = None
    if collapse_unknown:
        collapsed = ("- %d repos could not be read this week, so nothing is known about "
                     "them — that is usually a GitHub rate limit, not a problem with the "
                     "repos." % len(unknown))

    # ---- one trailing warning line, only when there is something in it
    missing, double, unparsed = warn_lines(rows)
    tail = []
    if missing:
        jobs = sum(len(p) for _, p in missing)
        tail.append("Also: %d build %s in %d %s have no time limit; a hang costs six "
                    "hours."
                    % (jobs, _plural(jobs, "job"), len(missing), _plural(len(missing), "repo")))
    if double:
        n = len(double)
        tail.append("Also: %d %s %s tests twice per change, which may be deliberate."
                    % (n, _plural(n, "repo"),
                       "runs its" if n == 1 else "run their"))
    if unparsed:
        # Without this the digest is SILENT about a build file nobody could read, and
        # silence in this message means "clean" — the rule the rest of this stage was
        # built on. The table has always carried the line; the digest did not (2026-09-14).
        nf = sum(len(w) for _, w in unparsed)
        tail.append("Note: %d build %s could not be read, so the notes above do not cover "
                    "them." % (nf, _plural(nf, "file")))
    if m["capped"]:
        tail.append("Note: %s ran more builds than were measured, so the minutes read "
                    "low." % ", ".join(m["capped"]))
    if m["measured"] and (method == "timing" or note):
        tail.append("Note: the build-time figure was measured the quick way this week and "
                    "reads low.")
    if parsers_used(rows).get("regex"):
        tail.append("Note: the check for repeated test runs could not run this week, so "
                    "nothing here says whether any repo has them.")
    if m["reason"] in ("skipped", "none"):
        # The other half of a skipped Actions pass, and the part that is easy to miss: the
        # approval-permission drift rule reads the same scan, so a repo that is genuinely
        # half set up counts as fine in the headline above. A silent week and an unchecked
        # week look identical unless the message says which one this was.
        #
        # It is only true of those two reasons. When the scan ran but the private repos'
        # builds could not be read, the permission check did run, and saying otherwise
        # would understate the headline in the other direction.
        tail.append("Note: the build-time and repository-permission checks were skipped "
                    "this week, so a repo could be half set up in a way this message "
                    "cannot see.")

    # ---- the one thing worth doing
    act = None
    # Sorted the way the body is, not the way `gh repo list` happened to answer: the
    # first drifter in API order can easily be the least urgent one while a worse repo
    # goes unnamed.
    drifters = sorted([r for r in rows if r["status"].startswith("drift")],
                      key=lambda x: (-(x.get("pr_count") or 0), x["name"]))
    if drifters:
        # The repo's own line above already carries the diagnosis in full. Repeating it
        # here cost 22 words of a 150-word message and told the reader nothing twice, so
        # this line does the other half of the job: what to do, and where.
        d = drifters[0]
        act = ("To act: finish setting up %s — its line above says what is missing."
               % d["name"])
    elif total_prs and oldest is not None:
        who = sorted([r for r in rows if r.get("pr_count")],
                     key=lambda x: -(x.get("pr_oldest_days") or 0))[0]
        act = ("To act: %s's oldest update is %d %s old — merge or close it."
               % (who["name"], who["pr_oldest_days"],
                  _plural(who["pr_oldest_days"], "day")))
    # Every line above is written to a budget: the whole message has to stay under 150
    # words (the brief's number, and the reason it is readable on a phone). The real
    # 2026-09-14 run came out at 202 — six full "update pull requests waiting" phrases
    # under a headline that had just said it, and two warning lines with a clause each
    # that carried no news. check-audit.sh pins the total against an account-sized
    # fixture, because the four-repo one would never have caught it.
    else:
        act = "To act: nothing. Everything enrolled is current."

    # ---- fit the whole thing under the word cap, by giving up repo lines and nothing else
    #
    # The real 2026-09-14 message ran to 202 words against the brief's 150, and the
    # obvious fix — a fixed cap of five repo lines — still landed at 154, because the
    # length that varies is not only the repo list. A later note (an unreadable build
    # file, say) would have walked straight back over the line, silently, in the one
    # output nobody re-measures.
    #
    # So the cap is enforced rather than aimed at, and the thing that gives way is the
    # repo list — the only part that is enumerable, is already sorted worst-first, and
    # says out loud how many it left out. The notes never give way: each one exists
    # because its absence would read as "nothing wrong here".
    for keep in range(min(BODY_LINES, len(repo_lines)), -1, -1):
        parts = _assemble(head, repo_lines, keep, collapsed, tail, act)
        if _words(parts) <= WORD_CAP or keep == 0:
            break
    for part in parts:
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
                    help="how minutes were measured: jobs | timing | skipped | none. "
                         "skipped and none both mean NOT MEASURED — no figure is printed "
                         "for either, and never a zero")
    ap.add_argument("--note", default="", help="a caveat to print alongside the minutes")
    ap.add_argument("--today", default=None,
                    help="pin the run date (YYYY-MM-DD) instead of using the clock. The "
                         "projection divides by days elapsed, so fixtures tuned against "
                         "the real date silently start failing later in the month")
    args = ap.parse_args()

    today = dt.date.fromisoformat(args.today) if args.today else None
    rows = load(sys.stdin)
    if args.mode == "json":
        json.dump({"generated": dt.datetime.now(dt.timezone.utc)
                   .strftime("%Y-%m-%dT%H:%M:%SZ"),
                   "owner": args.owner, "since": args.since, "run_cap": args.cap,
                   "allowance_minutes": ALLOWANCE,
                   "summary": counts(rows),
                   "minutes_method": args.method,
                   "minutes_note": args.note or None,
                   "minutes_measured": args.method not in UNMEASURED,
                   "minutes": {k: (v.isoformat() if hasattr(v, "isoformat") else v)
                               for k, v in minutes_picture(rows, args.since,
                                                           args.method, today).items()},
                   "repos": rows}, sys.stdout, indent=2, sort_keys=True)
        print()
    elif args.mode == "digest":
        render_digest(rows, args.owner, args.since, args.cap, sys.stdout,
                      args.method, args.note, today)
    else:
        render_table(rows, args.owner, args.since, args.cap, sys.stdout,
                     args.method, args.note, today)


if __name__ == "__main__":
    main()
