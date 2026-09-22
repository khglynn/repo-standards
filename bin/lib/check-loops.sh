#!/usr/bin/env bash
# Fixture tests for the open loops (2026-09-22). Run by CI.
#
#   bin/lib/check-loops.sh               run every assertion
#   bin/lib/check-loops.sh --regenerate  rewrite fixtures/loops/expected.json from facts.json
#                                        (then READ the diff before committing it)
#
# Four things can lie quietly here, and each section pins one:
#
# 1. THE SCANNER'S RULES — which pull request counts as a loop, the one reason it is stuck,
#    and which checks count as failed. Pure functions, run for real through Python.
# 2. THE DERIVATION, end to end, from a facts file with one case per rule to a pinned list.
#    Includes the cases that must NOT be loops (a 7-day-old PR, a queued update still
#    running) and the ones that must be reported as UNREAD rather than as clean.
# 3. THE DIGEST AND TABLE — the numbered block, the word cap, and above all the rule this
#    audit was built on: a measurement that did not happen reads as "not checked", never
#    as an empty list, because an empty list is what a good week looks like.
# 4. THE WORKFLOW'S WATCH — the jq in step 7 of the shared workflow that decides "failed",
#    "passed" or "pending" from a PR's checks, EXTRACTED from the workflow rather than
#    retyped (the check-classifier.sh pattern), and checked against the scanner's own list
#    of failed states, because those are two copies of one rule.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$HERE"
fail=0
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
FX=bin/lib/fixtures/loops

if [ "${1:-}" = "--regenerate" ]; then
  { echo '{"_about": "loops-scan.py --derive facts.json, pinned. Regenerate deliberately with bin/lib/check-loops.sh --regenerate, READ the diff, then commit it: a regenerated fixture nobody read is no fixture at all (the same rule as verdict-matrix.txt)."}'
    python3 bin/lib/loops-scan.py --owner example --derive "$FX/facts.json" | jq '{loops, measured}'
  } | jq -s '.[0] + .[1]' > "$FX/expected.json"
  echo "rewrote $FX/expected.json — read the diff before committing it"; exit 0
fi

ASSERTIONS=0
FAILURES=0
pass() { ASSERTIONS=$((ASSERTIONS + 1)); echo "ok: $*"; }
nope() { ASSERTIONS=$((ASSERTIONS + 1)); FAILURES=$((FAILURES + 1)); fail=1; echo "FAIL: $*"; }
say() { if [ "$2" = "$3" ]; then pass "$1"; else nope "$1 — got '$2', wanted '$3'"; fi; }
has() {  # has <label> <text> <needle>
  if grep -qF -- "$3" <<< "$2"; then pass "$1"; else nope "$1 — missing \"$3\""; printf '%s\n' "$2"; fi
}
hasnt() {
  if grep -qF -- "$3" <<< "$2"; then nope "$1 — still contains \"$3\""; else pass "$1"; fi
}

echo "--- 1. the scanner's rules, run for real"
got=$(python3 - <<'PYEOF'
import importlib.util, json, os
spec = importlib.util.spec_from_file_location("ls", os.path.join("bin", "lib", "loops-scan.py"))
ls = importlib.util.module_from_spec(spec); spec.loader.exec_module(ls)
out = {}

# evaluate_checks: failed / pending / passed / never reported / unreadable
ev = ls.evaluate_checks
out["fail"] = ev(["unit"], [("unit", "FAILURE"), ("other", "SUCCESS")], True)["failing"]
out["cancelled_is_failed"] = ev(["unit"], [("unit", "CANCELLED")], True)["failing"]
out["cancelled_twin_of_a_pass"] = ev(["unit"], [("unit", "CANCELLED"), ("unit", "SUCCESS")], True)["passed"]
out["cancelled_while_rerun_runs"] = ev(["unit"], [("unit", "CANCELLED"), ("unit", "IN_PROGRESS")], True)["pending"]
out["hard_beats_a_pass"] = ev(["unit"], [("unit", "FAILURE"), ("unit", "SUCCESS")], True)["failing"]
out["one_matrix_leg_red"] = ev(["checks"], [("checks", "SUCCESS"), ("checks", "FAILURE")], True)["failing"]
out["running"] = ev(["unit"], [("unit", "IN_PROGRESS")], True)["pending"]
out["skipped_passes"] = ev(["unit"], [("unit", "SKIPPED")], True)["passed"]
out["never_reported_complete"] = ev(["Vercel"], [("unit", "SUCCESS")], True)["missing"]
out["never_reported_incomplete"] = ev(["Vercel"], [("unit", "SUCCESS")], False)["unread"]
out["status_error"] = ev(["Vercel"], [("Vercel", "ERROR")], True)["failing"]

# pr_state: precedence, most fundamental first
ps = ls.pr_state
base = {"isDraft": False, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": None}
def st(chk=None, **kw):
    pr = dict(base); pr.update(kw); return ps(pr, chk)
red = {"failing": ["unit"], "pending": [], "missing": [], "unread": []}
run = {"failing": [], "pending": ["unit"], "missing": [], "unread": []}
blind = {"failing": [], "pending": [], "missing": [], "unread": ["Vercel"]}
out["states"] = {
  "ready": st(),
  "draft_beats_conflict": st(isDraft=True, mergeable="CONFLICTING"),
  "conflict_beats_red": st(red, mergeable="CONFLICTING", mergeStateStatus="DIRTY"),
  "red_beats_review": st(red, mergeStateStatus="BLOCKED", reviewDecision="REVIEW_REQUIRED"),
  "review_beats_running": st(run, mergeStateStatus="BLOCKED", reviewDecision="REVIEW_REQUIRED"),
  "running": st(run, mergeStateStatus="BLOCKED"),
  "behind": st(mergeStateStatus="BEHIND"),
  "blocked_unread": st(blind, mergeStateStatus="BLOCKED"),
  "blocked_no_checks_read": st(None, mergeStateStatus="BLOCKED"),
  "unstable_is_mergeable": st(mergeStateStatus="UNSTABLE"),
  "unknown": st(mergeStateStatus="UNKNOWN", mergeable="UNKNOWN"),
}

# The GraphQL client refuses a write before sending anything.
try:
    ls.Gql("x").query("mutation { addLabelsToLabelable(input: {}) { clientMutationId } }")
    out["mutation"] = "SENT"
except ValueError:
    out["mutation"] = "refused"

# Link-header cursors (the alerts endpoint answers 400 to page=)
out["next"] = ls._next_link({"Link": '<https://api.github.com/x?after=abc>; rel="next", <https://api.github.com/x?before=z>; rel="prev"'})
out["last_page"] = ls._next_link({"Link": '<https://api.github.com/x?before=z>; rel="prev"'})

# read_rules and read_security against a fake GET client
class Fake:
    exhausted = False
    def __init__(self, table): self.table = table
    def get(self, path):
        for key, val in self.table.items():
            if key in path:
                return val
        return None, type("E", (), {"code": 404})()
E403 = type("E", (), {"code": 403})()
rules = ls.read_rules(Fake({"rules/branches": ([
    {"type": "pull_request", "ruleset_id": 7, "parameters": {"required_approving_review_count": 1}},
    {"type": "pull_request", "ruleset_id": 8, "parameters": {"required_approving_review_count": 2}},
    {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "unit"}]}}], {})}),
    "o/r", "main")
out["rules"] = [rules["approvals"], rules["required"], rules["ruleset_ids"]]
out["rules_unreadable"] = ls.read_rules(Fake({"rules/branches": (None, E403)}), "o/r", "main")["approvals"]
classic = ls.read_rules(Fake({"rules/branches": ([], {}), "protection": ({
    "required_status_checks": {"contexts": ["ci"]},
    "required_pull_request_reviews": {"required_approving_review_count": 1}}, {})}), "o/r", "main")
out["classic"] = [classic["approvals"], classic["required"], classic["source"]]
out["classic_403"] = ls.read_rules(Fake({"rules/branches": ([], {}), "protection": (None, E403)}), "o/r", "main")["approvals"]

import datetime as dt
today = dt.date(2026, 9, 22)
alert = lambda sev, scope, fix: {"created_at": "2026-09-11T00:00:00Z", "dependency": {"scope": scope},
    "security_advisory": {"severity": sev},
    "security_vulnerability": {"first_patched_version": {"identifier": "1.0.1"} if fix else None}}
class Paged(Fake):
    def get(self, path):
        if "automated-security-fixes" in path: return {"enabled": True, "paused": False}, {}
        if "after=p2" in path: return [alert("high", "runtime", True)], {}
        if "dependabot/alerts" in path:
            return [alert("critical", "runtime", True), alert("low", "development", False)], \
                   {"Link": '<https://api.github.com/repos/o/r/dependabot/alerts?after=p2>; rel="next"'}
        if "actions/workflows/55/runs" in path:
            return {"workflow_runs": [{"created_at": "2026-09-01T00:00:00Z"}]}, {}
        if "actions/workflows" in path:
            return {"workflows": [
                {"id": 55, "path": "dynamic/dependabot/dependabot-updates"},
                {"id": 66, "path": "dynamic/github-code-scanning/codeql"},
                {"id": 77, "path": ".github/workflows/ci.yml"}]}, {}
        return None, E403
sec = ls.read_security(Paged({}), "o/r", today, 14)
out["security"] = {k: sec[k] for k in ("alerts", "fixable", "fixable_runtime", "critical", "high", "last_run", "runs_recent")}
out["security_blind"] = ls.read_security(Fake({"automated-security-fixes": ({"enabled": True}, {}),
                                               "dependabot/alerts": (None, E403)}), "o/r", today, 14)["errors"]
out["security_off"] = ls.read_security(Fake({"automated-security-fixes": ({"enabled": False}, {})}), "o/r", today, 14)["fixes_on"]
# No Dependabot workflow at all is a MEASURED "never", not an unread.
class NeverRan(Paged):
    def get(self, path):
        if "actions/workflows" in path:
            return {"workflows": [{"id": 66, "path": "dynamic/github-code-scanning/codeql"}]}, {}
        return Paged.get(self, path)
nr = ls.read_security(NeverRan({}), "o/r", today, 14)
out["never_ran"] = [nr["last_run"], nr["runs_recent"], nr["errors"]]

# The Actions fallback (a token that cannot read check runs): every job, no de-dup by
# name, and a required name found nowhere is UNREAD — it may be another app's check run.
class Blind:
    def query(self, doc, v=None):
        return None, [{"message": "Resource not accessible by personal access token"}], None
class Jobs:
    exhausted = False
    def get(self, path):
        if "actions/runs?head_sha" in path:
            return {"workflow_runs": [{"id": 1}, {"id": 2}]}, {}
        if "runs/1/jobs" in path:
            return {"jobs": [{"name": "checks", "status": "completed", "conclusion": "success"},
                             {"name": "checks", "status": "completed", "conclusion": "failure"}]}, {}
        if "runs/2/jobs" in path:
            return {"jobs": [{"name": "lint", "status": "in_progress"}]}, {}
        if path.endswith("/status"):
            return {"statuses": [{"context": "Vercel", "state": "success"}]}, {}
        return None, E403
fb = ls.read_checks(Jobs(), Blind(), "o", "r", 1, "sha", ["checks", "Vercel", "CodeQL"])
out["fallback"] = {k: fb[k] for k in ("failing", "passed", "missing", "unread", "source")}
print(json.dumps(out, sort_keys=True))
PYEOF
)
j() { jq -c "$1" <<< "$got"; }
say "a failed required check is failing"               "$(j .fail)" '["unit"]'
say "a cancelled required check blocks like a failure" "$(j .cancelled_is_failed)" '["unit"]'
say "…unless a twin of the same name passed"            "$(j .cancelled_twin_of_a_pass)" '["unit"]'
say "…and a re-run still going is pending"              "$(j .cancelled_while_rerun_runs)" '["unit"]'
say "a hard failure is red even beside a pass"          "$(j .hard_beats_a_pass)" '["unit"]'
say "one red matrix leg makes the check red"           "$(j .one_matrix_leg_red)" '["checks"]'
say "an unfinished check is pending"                   "$(j .running)" '["unit"]'
say "a skipped required check passes (GitHub's rule)"  "$(j .skipped_passes)" '["unit"]'
say "never reported, everything readable: missing"     "$(j .never_reported_complete)" '["Vercel"]'
say "never reported, something unreadable: UNREAD"     "$(j .never_reported_incomplete)" '["Vercel"]'
say "a commit status in error is failing"              "$(j .status_error)" '["Vercel"]'
say "pr states, most fundamental first" "$(j .states)" \
  '{"behind":"behind","blocked_no_checks_read":"blocked-unread","blocked_unread":"blocked-unread","conflict_beats_red":"conflicting","draft_beats_conflict":"draft","ready":"ready","red_beats_review":"checks-failing","review_beats_running":"review-required","running":"checks-pending","unknown":"unknown","unstable_is_mergeable":"ready"}'
say "the GraphQL client refuses a mutation"            "$(j .mutation)" '"refused"'
say "Link header: next page found"                     "$(j .next)" '"https://api.github.com/x?after=abc"'
say "Link header: no next on the last page"            "$(j .last_page)" 'null'
say "rulesets: the highest approval count, the checks, the rulesets that ask" "$(j .rules)" '[2,["unit"],[7,8]]'
say "rules unreadable: approvals unknown (null), not 0" "$(j .rules_unreadable)" 'null'
say "classic protection when there are no rulesets"    "$(j .classic)" '[1,["ci"],"classic"]'
say "classic protection refused: unknown, not 0"       "$(j .classic_403)" 'null'
say "security: cursor pages, fixable only, runtime, severities, Dependabot runs only" "$(j .security)" \
  '{"alerts":3,"critical":1,"fixable":2,"fixable_runtime":2,"high":1,"last_run":"2026-09-01","runs_recent":0}'
say "alerts refused: an error, never zero alerts"      "$(j .security_blind)" '["security alerts unreadable (HTTP 403)"]'
say "security fixes off: nothing more is read"          "$(j .security_off)" 'false'
say "no Dependabot workflow at all: a measured never"   "$(j .never_ran)" '[null,0,[]]'
say "fallback: every leg counts, another app's check is unread, a status is read" "$(j .fallback)" \
  '{"failing":["checks"],"missing":[],"passed":["Vercel"],"source":"actions","unread":["CodeQL"]}'

echo "--- 1b. gather(), the network half, against fakes"
# The per-repo reads and the check reads are glued together here, and the glue is where the
# first per-repo version went wrong: it checked the tests of the LAST repo's pull requests
# only (a loop variable shadowed the account-wide list), so every red queued update in any
# other repo vanished, silently. Two repos, the red one first, one worker: that exact order.
got=$(python3 - <<'PYEOF'
import importlib.util, json, os, datetime as dt
spec = importlib.util.spec_from_file_location("ls", os.path.join("bin", "lib", "loops-scan.py"))
ls = importlib.util.module_from_spec(spec); spec.loader.exec_module(ls)
PR = {"number": 7, "title": "t", "url": "u", "createdAt": "2026-09-20T00:00:00Z", "isDraft": False,
      "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED", "reviewDecision": None,
      "author": {"login": "dependabot"}, "repository": {"name": "red"}, "baseRefName": "main",
      "headRefOid": "h7", "autoMergeRequest": {"enabledAt": "2026-09-20T00:01:00Z"}}
class G:
    def query(self, doc, v=None):
        if "pullRequests(states" in doc:
            nodes = [PR] if v["r"] == "red" else []
            return {"repository": {"pullRequests": {"pageInfo": {"hasNextPage": False}, "nodes": nodes}}}, [], None
        if "statusCheckRollup" in doc:
            return {"repository": {"pullRequest": {"commits": {"nodes": [{"commit": {"statusCheckRollup": {
                "contexts": {"nodes": [{"__typename": "CheckRun", "name": "unit", "status": "COMPLETED",
                                        "conclusion": "FAILURE"}]}}}}]}}}}, [], None
        return None, [], None
class C:
    exhausted = False
    def get(self, path):
        if "rules/branches" in path:
            return [{"type": "required_status_checks",
                     "parameters": {"required_status_checks": [{"context": "unit"}]}}], {}
        if "automated-security-fixes" in path:
            return {"enabled": False}, {}
        return None, type("E", (), {"code": 404})()
facts = ls.gather(C(), G(), "o", [("red", "main", "PUBLIC", False), ("quiet", "main", "PUBLIC", False)],
                  dt.date(2026, 9, 22), 7, 14, True, 1)
loops, measured = ls.derive_loops(facts)
print(json.dumps({"checked": sorted(facts["checks"]), "loops": [(l["repo"], l.get("number"), l.get("state")) for l in loops],
                  "prs_unread": facts["prs_unread"]}))
PYEOF
)
say "the red repo's queued update had its tests read" "$(jq -c .checked <<< "$got")" '["red#7"]'
say "…and is a loop"                                  "$(jq -c .loops <<< "$got")" '[["red",7,"checks-failing"]]'
say "…and nothing was unreadable"                      "$(jq -c .prs_unread <<< "$got")" '[]'

echo "--- 2. the derivation, facts to loops, pinned"
if diff -u <(jq -S '{loops, measured}' "$FX/expected.json") \
           <(python3 bin/lib/loops-scan.py --owner example --derive "$FX/facts.json" | jq -S '{loops, measured}') \
           > "$WORK/diff"; then
  pass "facts.json derives exactly the pinned loops ($(jq '.loops | length' "$FX/expected.json") of them)"
else
  nope "the derivation changed"; head -40 "$WORK/diff" | sed 's/^/     /'
  echo "     (if intended: bin/lib/check-loops.sh --regenerate, read the diff, commit it)"
fi
# …and the rules behind that list, said in words so a regenerated fixture cannot quietly
# drop one of them.
D=$(python3 bin/lib/loops-scan.py --owner example --derive "$FX/facts.json")
say "a 7-day-old PR is not a loop (older than 7 means 8+)" \
    "$(jq '[.loops[] | select(.repo=="alpha" and .number==9)] | length' <<< "$D")" "0"
say "a queued update with FAILED tests is a loop at 6 days" \
    "$(jq -c '[.loops[] | select(.number==241) | .state, .queued]' <<< "$D")" '["checks-failing",true]'
say "a queued update still running is not a loop" \
    "$(jq '[.loops[] | select(.number==242)] | length' <<< "$D")" "0"
say "a queued update whose tests could not be read is counted as unread" \
    "$(jq -c '[.measured.checks_unread[] | select(. == "delta#22")]' <<< "$D")" '["delta#22"]'
say "…and so is one whose check read never came back at all" \
    "$(jq -c '[.measured.checks_unread[] | select(. == "lima#50")]' <<< "$D")" '["lima#50"]'
say "a queued update whose required check never reported, a day on, is a loop" \
    "$(jq -c '[.loops[] | select(.repo=="india" and .number==30) | .state]' <<< "$D")" '["check-missing"]'
say "…but not on the day it opened" \
    "$(jq '[.loops[] | select(.repo=="india" and .number==31)] | length' <<< "$D")" "0"
say "a queued update that conflicts AND is red is still a loop, shown as the conflict" \
    "$(jq -c '[.loops[] | select(.repo=="juliet") | .state, .failing]' <<< "$D")" '["conflicting",["unit"]]'
say "a repo whose scan raised is unread on rules and security, not absent" \
    "$(jq -c '[(.measured.rules_unread | index("kilo") != null), (.measured.security_unread | index("kilo") != null)]' <<< "$D")" '[true,true]'
say "the review rule carries the PR it strands" \
    "$(jq -c '[.loops[] | select(.kind=="approvals" and .repo=="bravo") | .stranded]' <<< "$D")" '[[2]]'
say "classic protection's review count is drift too" \
    "$(jq -c '[.loops[] | select(.kind=="approvals" and .repo=="hotel") | .approvals, .source]' <<< "$D")" '[2,"classic"]'
say "silent security fixes: on, fixable alerts, no run, no open update PR" \
    "$(jq -c '[.loops[] | select(.kind=="silent-security") | .repo]' <<< "$D")" '["echo"]'
say "an open Dependabot PR means Dependabot is running there" \
    "$(jq '[.loops[] | select(.kind=="silent-security" and .repo=="foxtrot")] | length' <<< "$D")" "0"
say "unreadable alerts and an unmeasured run count are UNREAD, not quiet" \
    "$(jq -c '.measured.security_unread' <<< "$D")" '["charlie","golf","kilo"]'
say "unreadable rules are UNREAD, not zero approvals" \
    "$(jq -c '.measured.rules_unread' <<< "$D")" '["delta","kilo"]'
say "oldest first" \
    "$(jq -c '[.loops[].age_days]' <<< "$D")" '[302,21,20,12,11,11,11,6,3,2,0]'
# A search that failed: no PR loops, and the digest must be told, not handed an empty list.
NOPRS=$(jq '.prs = null' "$FX/facts.json" > "$WORK/noprs.json" && python3 bin/lib/loops-scan.py --owner example --derive "$WORK/noprs.json")
say "a failed search is measured.prs=false" "$(jq '.measured.prs' <<< "$NOPRS")" "false"
say "…and yields no PR loops" "$(jq '[.loops[] | select(.kind=="pr")] | length' <<< "$NOPRS")" "0"
say "…and makes 'no open update PR' unknowable, so silent-security candidates are unread" \
    "$(jq -c '.measured.security_unread' <<< "$NOPRS")" '["charlie","echo","foxtrot","golf","kilo"]'

# One repo's pull requests unreadable: that repo is unknown, the rest still counted.
PART=$(jq '.prs_unread = ["foxtrot"] | .prs |= map(select(.repository.name != "foxtrot"))' "$FX/facts.json" > "$WORK/part.json" && python3 bin/lib/loops-scan.py --owner example --derive "$WORK/part.json")
say "one repo's PRs unreadable is named" "$(jq -c '.measured.prs_unread' <<< "$PART")" '["foxtrot"]'
say "…and its security fixes become unknown, not 'silent'" \
    "$(jq -c '[.measured.security_unread[] | select(. == "foxtrot")]' <<< "$PART")" '["foxtrot"]'
say "…while the other repos' loops are all still there" \
    "$(jq '[.loops[] | select(.kind=="pr")] | length' <<< "$PART")" "7"
printf '%s\n' "$PART" > "$WORK/loops-part.json"

echo "--- 3. the digest, the table and the JSON"
LOOPS="$WORK/loops.json"; printf '%s\n' "$D" > "$LOOPS"
printf '%s\n' "$NOPRS" > "$WORK/loops-noprs.json"
render() { python3 bin/lib/render-audit.py --owner khglynn --since 2026-09-01 --today 2026-09-22 "$@"; }
# The four-repo rows minus the drifter, so the "To act:" line is free to name a loop.
QUIET=$(grep -v '"status":"drift' bin/lib/fixtures/audit/rows.jsonl)
DG=$(render --mode digest --loops "$LOOPS" --word-cap 400 <<< "$QUIET")
has "the block is there, oldest first"      "$DG" "Open loops, oldest first:"
has "stale PRs grouped by the reason they are stuck" "$DG" "Ready to merge but still open (oldest 302 days): alpha #3 and foxtrot #1."
has "a red queued update says it will never merge" "$DG" "Tests fail, so these queued updates never merge (6 days): charlie #241."
has "one line for every review rule, with what it strands" "$DG" "Rules still require an approving review in 2 repos, holding up 1 pull request: bravo and hotel."
has "one line for silent security fixes, with the critical count" "$DG" "Security fixes on but never run in 1 repo, 100 fixable alerts (2 critical): echo."
has "a conflict is its own reason, members oldest first" "$DG" "Merge conflicts (oldest 21 days): echo #5 and juliet #40."
has "a check that never reported is its own reason" "$DG" "A required check never reported (2 days): india #30."
has "a draft is its own reason"              "$DG" "Drafts left open (20 days): echo #6."
hasnt "a PR held by a review rule is not listed twice" "$DG" "bravo #2"
has "tests that could not be read are said"  "$DG" "Note: tests on 2 pull requests could not be read."
has "rules that could not be read are said"  "$DG" "Note: review rules could not be read in 2 repos."
has "security fixes that could not be checked are said" "$DG" "Note: security fixes could not be checked in 3 repos."
has "To act picks the most urgent loop, not the oldest" "$DG" "To act: find out why security fixes never run in echo — 100 fixable alerts (2 critical)."
# …and says "stopped" rather than "never" when Dependabot did run once, with a singular
# alert read as one alert (both wrong in the first cut, found by review).
ONCE=$(jq '.loops |= map(if .kind=="silent-security" then .last_run="2026-08-01" | .fixable=1 else . end)' "$LOOPS")
printf '%s\n' "$ONCE" > "$WORK/loops-once.json"
has "a repo where Dependabot ran once: stopped, not never, and one alert" \
    "$(render --mode digest --loops "$WORK/loops-once.json" --word-cap 400 <<< "$QUIET")" \
    "To act: find out why security fixes stopped running in echo — 1 fixable alert (2 critical)."
if grep -qE '<[^ ]' <<< "$DG"; then nope "the loops block contains angle brackets (Slack link markup)"
else pass "no angle brackets"; fi
# The drifter still outranks every loop: finishing enrolment is the digest's first job.
DRIFT=$(render --mode digest --loops "$LOOPS" --word-cap 400 < bin/lib/fixtures/audit/rows.jsonl)
has "a half-set-up repo still wins the To act line" "$DRIFT" "To act: finish setting up list-maker"

# The cap. Under it by default at account size, and the loops say how many they left out.
# The cap, on a week where everything was read (the realistic case: the stress fixture's
# five unread-notes never give way, by design, and alone would carry it past 150).
READ_ALL=$(jq '.measured |= (.checks_unread = [] | .rules_unread = [] | .security_unread = [])' "$LOOPS")
printf '%s\n' "$READ_ALL" > "$WORK/loops-read.json"
WD=$(render --mode digest --loops "$WORK/loops-read.json" < bin/lib/fixtures/audit/rows-wide.jsonl)
n=$(wc -w <<< "$WD" | tr -d ' ')
if [ "$n" -lt 150 ]; then pass "account-sized digest with loops is $n words (cap 150)"
else nope "account-sized digest with loops is $n words, cap is 150"; echo "$WD"; fi
# At account size there must be SOMETHING about the loops: a numbered line, or the one-line
# count. A header over an orphaned "And N more" is what the first cut printed.
if grep -qE '^1\. |^Open loops: [0-9]+ this week' <<< "$WD"; then pass "…and it still says something about the loops"
else nope "the account-sized digest lost the loops entirely"; echo "$WD"; fi
if grep -qE '^Open loops, oldest first:$' <<< "$WD" && ! grep -qE '^1\. ' <<< "$WD"; then
  nope "a loops header with no numbered line under it"; echo "$WD"
else pass "no loops header without a numbered line"; fi
TIGHT=$(render --mode digest --loops "$LOOPS" --word-cap 170 <<< "$QUIET")
if grep -qE '^And [0-9]+ more open loops?\.$' <<< "$TIGHT"; then
  pass "a cut loop list says how many it left out"
else nope "the loop list was cut in silence"; printf '%s\n' "$TIGHT"; fi
# "And N more" counts loops (pull requests and repos), not the lines that group them.
shown=$(grep -cE '^[0-9]+\. ' <<< "$TIGHT" || true)
say "…and counts loops, not lines" "$(grep -oE '^And [0-9]+' <<< "$TIGHT" | grep -oE '[0-9]+')" \
    "$(python3 - "$LOOPS" "$shown" <<'PYEOF'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("r", os.path.join("bin", "lib", "render-audit.py"))
r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
doc = json.load(open(sys.argv[1])); doc["state"] = "ok"
print(sum(c for _, _, c in r.loop_items(doc)[int(sys.argv[2]):]))
PYEOF
)"
has "…and the notes survive the cut" "$TIGHT" "Note: tests on 2 pull requests could not be read."
ZERO=$(render --mode digest --loops "$LOOPS" --word-cap 60 <<< "$QUIET")
has "no room for any line: one sentence with the count and the oldest age" "$ZERO" "Open loops: 10 this week, the oldest 302 days old."
hasnt "…and no orphaned 'And N more'" "$ZERO" "more open loop"
# The repo list gives way before the loops, and never leaves an orphaned "and N more".
if grep -qE '^- and [0-9]+ more' <<< "$(render --mode digest --loops "$LOOPS" --word-cap 110 < bin/lib/fixtures/audit/rows-wide.jsonl)" \
   && ! grep -qE '^- [a-z]' <<< "$(render --mode digest --loops "$LOOPS" --word-cap 110 < bin/lib/fixtures/audit/rows-wide.jsonl | grep -v '^- and')"; then
  nope "an 'and N more' repo line with no repo line before it"
else pass "no orphaned 'and N more' repo line"; fi

# NOT CHECKED is never an empty list. Three ways to have no scan, one sentence for all.
for how in absent skipped unreadable; do
  case "$how" in
    absent) T=$(render --mode digest <<< "$QUIET") ;;
    skipped) T=$(render --mode digest --loops skipped <<< "$QUIET") ;;
    unreadable) T=$(render --mode digest --loops "$WORK/no-such-file.json" <<< "$QUIET") ;;
  esac
  has "digest ($how): says open loops were not checked" "$T" "Note: open loops were not checked this week."
  hasnt "digest ($how): no loops block pretending to be complete" "$T" "Open loops, oldest first:"
done
has "a scan that FAILED says so, in its own words" "$(render --mode digest --loops failed <<< "$QUIET")" \
    "Note: the open-loops scan failed this week, so none are listed."
has "…and the table does not call it --skip-loops" "$(render --mode table --loops failed <<< "$QUIET")" \
    "the open-loops scan FAILED"
jq '.errors = ["something nobody planned for"] | .measured |= (.checks_unread = [] | .rules_unread = [] | .security_unread = [])' "$LOOPS" > "$WORK/loops-err.json"
has "an error no specific note covers still gets a note" \
    "$(render --mode digest --loops "$WORK/loops-err.json" --word-cap 400 <<< "$QUIET")" \
    "Note: the open-loops scan hit an error, so the list may be incomplete."
NP=$(render --mode digest --loops "$WORK/loops-noprs.json" --word-cap 400 <<< "$QUIET")
has "a failed PR search is said, not shown as zero PRs" "$NP" "Note: open pull requests could not be read, so loops may be missing."
hasnt "…and no PR group is invented" "$NP" "Ready to merge"
has "one repo's unreadable pull requests are said" \
    "$(render --mode digest --loops "$WORK/loops-part.json" --word-cap 400 <<< "$QUIET")" \
    "Note: open pull requests could not be read in 1 repo."
# A clean, fully-read week has no block and no note: silence means clean only when measured.
CLEAN=$(render --mode digest --loops "$FX/none.json" <<< "$QUIET")
hasnt "a measured week with no loops prints no block" "$CLEAN" "Open loops"
hasnt "…and no not-checked note" "$CLEAN" "not checked"

TB=$(render --mode table --loops "$LOOPS" <<< "$QUIET")
has "table: every loop, oldest first"       "$TB" "**Open loops — 11, oldest first**"
has "table: the PR a rule strands is listed too" "$TB" "\`bravo\` #2 (Dependabot), 11 days: waiting on a review the rules require."
has "table: links"                          "$TB" "https://github.com/example/charlie/pull/241"
has "table: a queued red update says it will wait forever" "$TB" "auto-merge is queued and will wait forever"
has "table: plural alert count"             "$TB" "100 fixable alerts"
has "table: singular alert count"           "$(render --mode table --loops "$WORK/loops-once.json" <<< "$QUIET")" "1 fixable alert ("
has "table: not checked, said"              "$(render --mode table <<< "$QUIET")" "**Open loops — NOT CHECKED on this run**"
JS=$(render --mode json --loops "$LOOPS" <<< "$QUIET")
say "json: checked"           "$(jq '.open_loops.checked' <<< "$JS")" "true"
say "json: every loop"        "$(jq '.open_loops.loops | length' <<< "$JS")" "11"
JN=$(render --mode json <<< "$QUIET")
say "json: not checked"       "$(jq '.open_loops.checked' <<< "$JN")" "false"
say "json: loops null, not []" "$(jq '.open_loops.loops' <<< "$JN")" "null"

# The watch column: a stub that turns the watch ON without the two reads is named; one
# that leaves it off (the default) is not a problem and is never mentioned.
BLIND=$(jq -c 'if .name=="patchwork" then .stub_watch="blind" else .stub_watch="off" end' <<< "$QUIET" | render --mode table --loops "$FX/none.json")
has "table names a stub whose watch is on but blind" "$BLIND" "**Failed-test watch turned on but blind:** \`patchwork\`"
hasnt "…and says nothing about stubs that leave it off" \
    "$(jq -c '.stub_watch="off"' <<< "$QUIET" | render --mode table --loops "$FX/none.json")" "watch turned on"
BROAD=$(jq -c 'if .name=="patchwork" then .stub_broad=true else . end' <<< "$QUIET" | render --mode table --loops "$FX/none.json")
has "table names a stub that grants more than the workflow uses" "$BROAD" "**Stubs that grant more than the workflow uses:** \`patchwork\`"

echo "--- 4. the workflow's watch rule, taken straight out of the shared workflow"
WF=.github/workflows/dependabot-automerge.yml
WATCH=$(sed -n "/WATCH_JQ='/,/end'\$/p" "$WF" | sed -e "s/^.*WATCH_JQ='//" -e "s/'\$//")
if [ -z "$WATCH" ]; then nope "could not find WATCH_JQ in $WF — renamed?"; exit 1; fi
# A GraphQL answer shaped like the real one: `ctx` is a list of [type, name, status, result].
resp() {  # resp <state> <head> <ctx-json>
  jq -cn --arg st "$1" --arg head "$2" --argjson ctx "$3" '{data: {repository: {pullRequest: {
    state: $st, headRefOid: $head,
    commits: {nodes: [{commit: {statusCheckRollup: {contexts: {nodes: [ $ctx[] |
      if .[0] == "run" then {__typename: "CheckRun", name: .[1], status: .[2], conclusion: .[3]}
      else {__typename: "StatusContext", context: .[1], state: .[3]} end ]}}}}]}}}}}'
}
w() { jq -r --argjson req "$1" --arg head H "$WATCH" <<< "$2"; }  # w <required-json> <response>
say "a failed required job"            "$(w '["unit"]' "$(resp OPEN H '[["run","unit","COMPLETED","FAILURE"],["run","lint","COMPLETED","SUCCESS"]]')")" "failed:unit"
say "a failed non-required job is ignored" "$(w '["unit"]' "$(resp OPEN H '[["run","unit","COMPLETED","SUCCESS"],["run","lint","COMPLETED","FAILURE"]]')")" "passed"
say "one red matrix leg"               "$(w '["checks"]' "$(resp OPEN H '[["run","checks","COMPLETED","SUCCESS"],["run","checks","COMPLETED","FAILURE"]]')")" "failed:checks"
say "still running"                    "$(w '["unit"]' "$(resp OPEN H '[["run","unit","IN_PROGRESS",null]]')")" "pending"
say "not reported yet is missing, never passed" "$(w '["unit"]' "$(resp OPEN H '[["run","lint","COMPLETED","SUCCESS"]]')")" "missing:unit"
say "no checks at all yet"             "$(w '["unit"]' "$(resp OPEN H '[]')")" "missing:unit"
say "one running, one never reported: still pending" "$(w '["unit","Vercel"]' "$(resp OPEN H '[["run","unit","IN_PROGRESS",null]]')")" "pending"
say "a cancelled twin of a pass is passed" "$(w '["unit"]' "$(resp OPEN H '[["run","unit","COMPLETED","CANCELLED"],["run","unit","COMPLETED","SUCCESS"]]')")" "passed"
say "a check name with a comma (a matrix leg)" \
    "$(w '["test (ubuntu-latest, 3.11)"]' "$(resp OPEN H '[["run","test (ubuntu-latest, 3.11)","COMPLETED","FAILURE"]]')")" "failed:test (ubuntu-latest, 3.11)"
say "a skipped required job passes"    "$(w '["unit"]' "$(resp OPEN H '[["run","unit","COMPLETED","SKIPPED"]]')")" "passed"
say "cancelled counts as failed"       "$(w '["unit"]' "$(resp OPEN H '[["run","unit","COMPLETED","CANCELLED"]]')")" "failed:unit"
say "a commit status (Vercel) failing" "$(w '["Vercel"]' "$(resp OPEN H '[["status","Vercel",null,"FAILURE"]]')")" "failed:Vercel"
say "a commit status pending"          "$(w '["Vercel"]' "$(resp OPEN H '[["status","Vercel",null,"PENDING"]]')")" "pending"
say "two required, one still running"  "$(w '["unit","Vercel"]' "$(resp OPEN H '[["run","unit","COMPLETED","SUCCESS"],["status","Vercel",null,"PENDING"]]')")" "pending"
say "two required, both green"         "$(w '["unit","Vercel"]' "$(resp OPEN H '[["run","unit","COMPLETED","SUCCESS"],["status","Vercel",null,"SUCCESS"]]')")" "passed"
say "the head moved"                   "$(w '["unit"]' "$(resp OPEN OTHER '[["run","unit","COMPLETED","FAILURE"]]')")" "moved"
say "merged or closed"                 "$(w '["unit"]' "$(resp MERGED H '[]')")" "gone"
say "an error for the check runs (a token without checks: read)" \
    "$(w '["unit"]' '{"errors":[{"message":"Resource not accessible by integration"}],"data":{"repository":{"pullRequest":{"state":"OPEN","headRefOid":"H","commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}}}}')" "unread"
say "no pull request in the answer"    "$(w '["unit"]' '{"data":{"repository":{"pullRequest":null}}}')" "unread"

# Two copies of one rule: the three state lists in the watch and in the scanner.
lists() {  # lists <jq def name>  → the sorted names in the workflow's `def <name>: [...]`
  grep -E "def $1: \[" <<< "$WATCH" | grep -oE '"[A-Z_]+"' | tr -d '"' | sort | tr '\n' ' '
}
pylist() {
  python3 -c 'import importlib.util,os,sys
s=importlib.util.spec_from_file_location("ls",os.path.join("bin","lib","loops-scan.py"));m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
print(" ".join(sorted(getattr(m, sys.argv[1]))) + " ")' "$1"
}
say "the workflow and the scanner agree on HARD failures" "$(lists hard)" "$(pylist HARD)"
say "…on SOFT ones (cancelled, stale)"                    "$(lists soft)" "$(pylist SOFT)"
say "…and on what passing means"                          "$(lists pass)" "$(pylist PASSED)"
# …and step 6's stale-and-red warning counts the union, so it never disagrees with them.
STEP6=$(grep -oE 'select\(IN\("failure"[^)]*\)\)' "$WF" | grep -oE '"[a-z_]+"' | tr -d '"' | tr '[:lower:]' '[:upper:]' | sort | tr '\n' ' ')
# Word-splitting the two lists into one is the point here, so it is done by `tr`, not by
# an unquoted expansion.
say "step 6 counts exactly HARD + SOFT as red" "$STEP6" "$(printf '%s %s' "$(lists hard)" "$(lists soft)" | tr ' ' '\n' | grep . | sort | tr '\n' ' ')"

# The shared workflow must never declare its own permissions again: asking for one scope an
# older stub did not grant is a startup failure in every enrolled repo at once.
if grep -qE '^[[:space:]]*permissions:' "$WF"; then
  nope "the shared workflow declares permissions again — every older stub would fail to start"
else pass "the shared workflow inherits its permissions from the stub"; fi
# OFF BY DEFAULT (2026-09-22): merging the shared workflow must change nothing in a repo
# that has not opted in. The default is 0, the job's ceiling is still 10 minutes there, the
# new label is only created where the watch is on, and the template grants no new scope.
say "the watch is off by default" \
    "$(python3 -c 'import yaml;d=yaml.safe_load(open(".github/workflows/dependabot-automerge.yml"));print((d.get("on") or d.get(True))["workflow_call"]["inputs"]["watch-minutes"]["default"])')" "0"
# shellcheck disable=SC2016  # the ${{ }} and $IN_WATCH_MINUTES below are literal workflow text
say "…the job ceiling is 10 when it is off and 25 when it is on" \
    "$(grep -E '^[[:space:]]+timeout-minutes:' "$WF" | sed 's/^[[:space:]]*//')" \
    'timeout-minutes: ${{ inputs.watch-minutes > 0 && 25 || 10 }}'
# shellcheck disable=SC2016  # literal workflow text, not shell expansions
if grep -qE 'if \[ "\$IN_WATCH_MINUTES" -gt 0 \]; then' "$WF" \
   && [ "$(grep -c 'create "$LABEL_CI_FAILED"' "$WF")" = "1" ]; then
  pass "…the new label is created only where the watch is on"
else nope "the dependabot-ci-failed label is created even with the watch off"; fi
say "…and the stub template grants only the three scopes it always did" \
    "$(python3 -c 'import yaml;print(" ".join(sorted(yaml.safe_load(open("templates/caller-stub.yml"))["permissions"])))')" \
    "contents issues pull-requests"
say "…while keeping the recipe to turn the watch on, commented out" \
    "$(grep -cE '^[[:space:]]+# (checks|statuses): read' templates/caller-stub.yml)" "2"

echo
if [ "$fail" = "0" ]; then echo "check-loops: $ASSERTIONS assertions, 0 failures."
else echo "check-loops: $ASSERTIONS assertions, $FAILURES FAILED."; fi
exit "$fail"
