#!/usr/bin/env bash
# Fixture tests for the two places bin/audit can lie quietly. Run by CI.
#
# 1. THE TREE-READABILITY PREDICATE. Its previous form, `.truncated // "err"`, made every
#    repo read "could not read this repo's file list" for three days while printing a
#    full, confident table — jq's `//` treats **false** as empty, and `"truncated": false`
#    is precisely the good case. A wrong answer that looks like a working tool is the
#    failure mode this whole repo exists to prevent, so the predicate is pinned here and
#    EXTRACTED FROM bin/audit rather than retyped, the way check-classifier.sh does it.
#
# 2. THE DIGEST'S WORDING. `--digest` is the only output a person reads every week. These
#    assertions are about what must always be in it (the counts, the budget, one line per
#    repo that needs something) and what must never be (angle brackets, which Slack turns
#    into link markup — that bug already shipped once, BUILD-LOG 2026-09-11).
#
# 3. THE CLOCK. Every assertion below pins `--today 2026-09-14`. The projection divides
#    this month's minutes by the days elapsed, so a fixture tuned against the real date
#    passes in mid-September and fails in late September for no reason anyone would
#    connect to the change that day. Section 5's BIG case was exactly that: it asserted a
#    run-out date, and its 2,600 minutes only project past 3,000 while fewer than 26 days
#    have elapsed — so it was due to start failing on 27 Sep 2026. Found by review.
#
# Written 2026-09-14.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$HERE"
fail=0
TMPDIFF=$(mktemp); trap 'rm -f "$TMPDIFF"' EXIT

say() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2', wanted '$3'"; fail=1; fi; }

# One place to spell the pinned date and the renderer's path.
render() { python3 bin/lib/render-audit.py --owner khglynn --since 2026-09-01 \
                   --today 2026-09-14 "$@"; }

echo "--- 1. the tree-readability predicate, taken straight out of bin/audit"
JQ=$(grep '^TREE_STATE_JQ=' bin/audit | sed -e "s/^TREE_STATE_JQ='//" -e "s/'$//")
if [ -z "$JQ" ]; then echo "FAIL: could not find TREE_STATE_JQ in bin/audit"; exit 1; fi
say "a complete tree reads 'false'"  "$(echo '{"truncated":false,"tree":[]}' | jq -r "$JQ")" "false"
say "a truncated tree reads 'true'"  "$(echo '{"truncated":true,"tree":[]}'  | jq -r "$JQ")" "true"
say "an error body reads 'err'"      "$(echo '{"message":"Not Found"}'       | jq -r "$JQ")" "err"
say "a non-object reads 'err'"       "$(echo '[]'                            | jq -r "$JQ")" "err"

echo "--- 1b. the approve-switch predicate, same trap, also taken out of bin/audit"
# `.approve // "?"` turned a legitimate **false** — the one value the drift rule looks
# for — into "?", so the column would have read unknown on exactly the repos it exists
# to catch. Any jq default over a field that can be `false` needs this shape.
AJQ=$(grep '^APPROVE_JQ=' bin/audit | sed -e "s/^APPROVE_JQ='//" -e "s/'$//")
if [ -z "$AJQ" ]; then echo "FAIL: could not find APPROVE_JQ in bin/audit"; exit 1; fi
say "switch off reads 'false'"    "$(echo '{"approve":false}' | jq -r "$AJQ")" "false"
say "switch on reads 'true'"      "$(echo '{"approve":true}'  | jq -r "$AJQ")" "true"
say "unreadable reads '?'"        "$(echo '{"approve":null}'  | jq -r "$AJQ")" "?"
say "absent reads '?'"            "$(echo '{}'                | jq -r "$AJQ")" "?"

echo "--- 2. the digest"
FIX=bin/lib/fixtures/audit/rows.jsonl
DIGEST=$(render --mode digest < "$FIX")

# `--` matters: several of these start with a hyphen, which grep would read as a flag.
has() {
  if grep -qF -- "$1" <<< "$DIGEST"; then echo "ok: digest says \"$1\""
  else echo "FAIL: digest is missing \"$1\""; echo "$DIGEST"; fail=1; fi
}
hasnt() {
  if grep -qF -- "$1" <<< "$DIGEST"; then echo "FAIL: digest still contains \"$1\""; fail=1
  else echo "ok: digest has no \"$1\""; fi
}
has "1 of 4 repos keep themselves up to date"      # patchwork is a fork, ynai security-only
has "6 updates waiting, the oldest 26 days old"
has "about 1000 of the free 3,000 private-repo minutes"
has "- eachie —"                                   # has open PRs
has "- ynai —"                                     # has open PRs
has "- list-maker —"                               # drifting, no PRs
has "To act:"
hasnt "- patchwork"                                # a fork with nothing waiting: silent

# Angle brackets become link markup in Slack. This is a rule about the channel, not taste.
if grep -qE '<[^ ]' <<< "$DIGEST"; then echo "FAIL: digest contains angle brackets"; fail=1
else echo "ok: no angle brackets"; fi

# The headline is everything before the first repo line, and it has to stay glanceable.
words=$(sed -n '/^- /q;p' <<< "$DIGEST" | wc -w | tr -d ' ')
if [ "$words" -lt 120 ]; then echo "ok: headline is $words words (cap 120)"
else echo "FAIL: headline is $words words, cap is 120"; fail=1; fi

# And the WHOLE message against the brief's 150, which nothing checked until now: the
# real 2026-09-14 digest was 202 words while the routine prompt and the README both
# promised under 150, and the four-repo fixture is too small to have caught it. So the
# cap is asserted against an account-shaped fixture as well — 40 repos, six of them with
# updates waiting, both warnings live, one repo capped.
cap_words() {
  local label="$1" text="$2" n
  n=$(wc -w <<< "$text" | tr -d ' ')
  if [ "$n" -lt 150 ]; then echo "ok: $label digest is $n words (cap 150)"
  else echo "FAIL: $label digest is $n words, cap is 150"; echo "$text"; fail=1; fi
}
WIDE=bin/lib/fixtures/audit/rows-wide.jsonl
WIDE_DIGEST=$(render --mode digest < "$WIDE")
cap_words "four-repo" "$DIGEST"
cap_words "account-sized" "$WIDE_DIGEST"

# The repo list is the part that gives way, and it has to say how many it left out rather
# than dropping them in silence. (Six repos have updates waiting in that fixture.)
if grep -qE '^- and [0-9]+ more repos? needs? attention\.$' <<< "$WIDE_DIGEST"; then
  echo "ok: the collapsed repo lines are counted out loud"
else echo "FAIL: the account-sized digest dropped repo lines silently"; echo "$WIDE_DIGEST"; fail=1; fi

# …and adding one more note must compress the repo list further rather than run over.
WIDE_PLUS=$(python3 -c 'import json
rows = [json.loads(l) for l in open("bin/lib/fixtures/audit/rows-wide.jsonl")]
rows[0]["unparsed"] = ["ci.yml", "release.yml"]
print("\n".join(json.dumps(r) for r in rows))' | render --mode digest)
cap_words "account-sized plus an unreadable build file" "$WIDE_PLUS"
if grep -qF -- "could not be read, so the notes above do not cover them" <<< "$WIDE_PLUS"; then
  echo "ok: an unreadable build file reaches the digest, not just the table"
else echo "FAIL: the digest is silent about a build file nobody could read"; echo "$WIDE_PLUS"; fail=1; fi

# The capped-run caveat has to survive, or the minutes silently read low.
has "ran more builds than were measured"
# And the two warnings, which are warnings and must not be phrased as breakage.
has "have no time limit"
has "runs its tests twice"

echo "--- 3. a run that did NOT measure build time must never report a number"
# `bin/audit --digest --skip-actions` makes no Actions calls at all, and on 2026-09-14 it
# printed "about 0 minutes of the free 3,000 … the month ends near 0, inside the free
# pool" — a confident sentence about a measurement it never took, in the one output a
# person reads. Zero and absent are different facts. The fixture is the real shape of that
# run: every Actions-derived field absent rather than zero.
UNMEAS=bin/lib/fixtures/audit/rows-unmeasured.jsonl
for meth in skipped none; do
  D=$(render --mode digest --method "$meth" < "$UNMEAS")
  if grep -qF -- "was not checked this week" <<< "$D"; then echo "ok: digest ($meth) says build time was not checked"
  else echo "FAIL: digest ($meth) does not say build time went unmeasured"; echo "$D"; fail=1; fi
  for lie in "minutes of the free" "inside the free pool" "run out around"; do
    if grep -qF -- "$lie" <<< "$D"; then echo "FAIL: digest ($meth) still claims \"$lie\""; fail=1
    else echo "ok: digest ($meth) makes no claim of \"$lie\""; fi
  done
  # The enrolment half is still real on such a run and must still be reported — but it
  # reads 2 of 4, not the 1 of 4 above, because the approve-switch drift rule reads the
  # same scan that was skipped. That is the trap: a skipped run reports FEWER problems,
  # which is why the tail note below has to say the checks did not happen.
  if grep -qF -- "2 of 4 repos keep themselves up to date" <<< "$D"; then echo "ok: digest ($meth) still reports enrolment"
  else echo "FAIL: digest ($meth) lost the enrolment headline"; echo "$D"; fail=1; fi
  if grep -qF -- "could be half set up in a way this message cannot see" <<< "$D"; then echo "ok: digest ($meth) warns that drift went unchecked"
  else echo "FAIL: digest ($meth) does not warn that the drift check was skipped"; fail=1; fi

  T=$(render --mode table --method "$meth" < "$UNMEAS")
  if grep -qF -- "NOT MEASURED on this run" <<< "$T"; then echo "ok: table ($meth) says not measured"
  else echo "FAIL: table ($meth) does not say not measured"; fail=1; fi
  if grep -qE 'Private repos: \*\*[0-9]' <<< "$T"; then echo "FAIL: table ($meth) still prints a private-minutes figure"; fail=1
  else echo "ok: table ($meth) prints no private-minutes figure"; fi

  J=$(render --mode json --method "$meth" < "$UNMEAS")
  say "json ($meth) minutes_measured is false" "$(jq -r '.minutes_measured' <<< "$J")" "false"
  say "json ($meth) private minutes are null"  "$(jq -r '.minutes.private' <<< "$J")" "null"
  say "json ($meth) projection is null"        "$(jq -r '.minutes.projected' <<< "$J")" "null"
done

echo "--- 4. the parser is named, and the regex fallback's silence is not read as 'none'"
# The brief asked which YAML reader answered the two workflow warnings. It matters because
# the regex path DECLINES the double-trigger question rather than guessing, so on that path
# an empty list means not checked. Same zero-versus-absent rule, one level down.
REGEX_ROWS=$(python3 -c 'import json,sys
for line in open("bin/lib/fixtures/audit/rows.jsonl"):
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    row["parser"] = "regex"
    row["double_trigger"] = []
    print(json.dumps(row))')
RT=$(render --mode table <<< "$REGEX_ROWS")
if grep -qF -- "regex fallback" <<< "$RT"; then echo "ok: table names the regex fallback"
else echo "FAIL: table does not say the regex fallback ran"; fail=1; fi
if grep -qF -- "means not checked, not none" <<< "$RT"; then echo "ok: table says its silence is not 'none'"
else echo "FAIL: table lets the regex fallback's empty list read as clean"; fail=1; fi
RD=$(render --mode digest <<< "$REGEX_ROWS")
if grep -qF -- "could not run this week" <<< "$RD"; then echo "ok: digest says the repeated-run check did not run"
else echo "FAIL: digest is silent about the unchecked double trigger"; fail=1; fi
# And the normal path names PyYAML rather than saying nothing at all.
if grep -qF -- "parsed with PyYAML" <<< "$(render --mode table < "$FIX")"; then
  echo "ok: table names PyYAML on the normal path"
else echo "FAIL: table does not name the parser on the normal path"; fail=1; fi

echo "--- 5. excluded-and-free is not the same as unread, and a floor still gets a date"
# Dependabot's own update runs are excluded from the minutes (GitHub does not bill them).
# The first cut of the "could not be measured" test asked `runs and not timed`, which
# reported four repos whose ONLY run this month was one of those free ones as unmeasurable.
# A run deliberately excluded is not a run that went unread.
FREEONLY='{"name":"wkt","visibility":"PRIVATE","status":"security-only","prs":"0","pr_count":0,
 "pr_oldest_days":null,"minutes":0,"runs":1,"free_runs":1,"timed":0,"capped":false,
 "runners":[],"missing_timeout":[],"double_trigger":[],"unparsed":[],"parser":"pyyaml",
 "errors":[],"approve_cell":"true","auto_merge":"true","checks":"ci","dependabot":"no",
 "stub":"no","manifest":"yes","pushed":"2026-09-02","is_fork":false}'
# A second private repo that WAS read, so the run as a whole counts as measured and the
# per-repo "partial" question stays separable from the whole-run "measured" one.
READ=$(jq -c '.name="ok-repo" | .minutes=10 | .runs=3 | .free_runs=0 | .timed=3' <<< "$FREEONLY")

say "a repo whose only run was free is not 'partial'" \
    "$(printf '%s\n%s\n' "$(jq -c '.' <<< "$FREEONLY")" "$READ" \
        | render --mode json | jq -c '.minutes.partial')" "[]"
# …but a repo with billable runs and nothing timed still is.
say "billable runs with nothing timed IS 'partial'" \
    "$(printf '%s\n%s\n' "$(jq -c '.runs = 5 | .free_runs = 1' <<< "$FREEONLY")" "$READ" \
        | render --mode json | jq -c '.minutes.partial')" '["wkt"]'
# A partial read makes the total a FLOOR, so the run-out date moves earlier, not away.
# Suppressing it because the reading was incomplete withholds the more urgent news.
BIG=$(jq -c '.runs = 5 | .free_runs = 0 | .timed = 2 | .minutes = 2600
             | .errors = ["job timing unreadable (HTTP 403)"]' <<< "$FREEONLY")
BD=$(render --mode digest <<< "$BIG")
if grep -qF -- "run out around" <<< "$BD"; then echo "ok: a partial read still names the run-out date"
else echo "FAIL: the run-out date vanished on a partial read"; echo "$BD"; fail=1; fi
if grep -qF -- "that date could be sooner" <<< "$BD"; then echo "ok: and says the date could be sooner"
else echo "FAIL: partial read does not say the date could be sooner"; fail=1; fi

# And the measured path must keep saying a real number, or the fix above has gone too far.
say "a measured run still reports minutes" \
    "$(render --mode json --method jobs < "$FIX" | jq -r '.minutes.private')" "1000"

echo "--- 6. the other three doors the confident zero was still walking through"
# `measured` used to be keyed on the METHOD alone, which left three ways for
# "about 0 minutes of the free 3,000 … inside the free pool" to reach Slack about a
# measurement nobody took. All three are reproduced here against the real renderer.

# (a) No private repo was visible at all — a repo-scoped token in the cloud routine sees
#     none of them, every row is public, and 0 private minutes formats beautifully.
PUB=$(jq -c '.name="site" | .visibility="PUBLIC" | .minutes=40 | .runs=9 | .timed=9' <<< "$FREEONLY")
INVIS=$(printf '%s\n%s\n' "$PUB" "$(jq -c '.name="site2" | .visibility="PRIVATE" | .minutes=null | .runs=null | .timed=null' <<< "$FREEONLY")")
say "no private repo readable reads as not measured" \
    "$(render --mode json <<< "$INVIS" | jq -r '.minutes.measured')" "false"
say "…and names why" \
    "$(render --mode json <<< "$INVIS" | jq -r '.minutes.reason')" "invisible"
ID=$(render --mode digest <<< "$INVIS")
if grep -qF -- "No private repository's build time could be read this week" <<< "$ID"; then
  echo "ok: the digest says which kind of missing this was"
else echo "FAIL: the digest does not distinguish unreadable from unchecked"; echo "$ID"; fail=1; fi
# …and does NOT claim the permission check was skipped, because it was not.
if grep -qF -- "repository-permission checks were skipped" <<< "$ID"; then
  echo "FAIL: an unreadable-minutes run claims the permission check was skipped too"; fail=1
else echo "ok: the permission check is not claimed skipped when it ran"; fi
for lie in "minutes of the free" "inside the free pool" "private-repo minutes"; do
  if grep -qF -- "$lie" <<< "$ID"; then echo "FAIL: invisible-private digest claims \"$lie\""; fail=1
  else echo "ok: invisible-private digest makes no claim of \"$lie\""; fi
done

# (b) Every private repo with billable builds had all of them go unread — a 403 on each
#     Actions scan. The old code printed the zero AND, underneath it, "4 of the 4 repos
#     could not be measured". The first half read as good news.
UNREAD=$(jq -c '.runs = 9 | .free_runs = 0 | .timed = 0 | .minutes = 0
                | .errors = ["job timing unreadable (HTTP 403)"]' <<< "$FREEONLY")
say "every billable build unread reads as not measured" \
    "$(render --mode json <<< "$UNREAD" | jq -r '.minutes.measured')" "false"
say "…and names why" \
    "$(render --mode json <<< "$UNREAD" | jq -r '.minutes.reason')" "unread"
# An owner with no private repos at all is NOT unmeasured: nothing private ran, and that
# is a fact about the month rather than a hole in the reading.
say "an all-public owner still gets a real (zero) figure" \
    "$(render --mode json <<< "$PUB" | jq -r '.minutes.measured')" "true"

echo "--- 7. spending past the free 3,000 is said plainly, never as a forecast"
# A projection that lands BEHIND today used to print in the future tense — 3,500 minutes
# read on 14 September announced "the free minutes run out around 12 Sep". The arithmetic
# says that happens exactly when the allowance is already spent (render-audit.py explains
# why), so the one thing to prove is that the over-budget case never prints a date.
OVER=$(jq -c '.runs = 40 | .free_runs = 0 | .timed = 40 | .minutes = 3400' <<< "$FREEONLY")
OD=$(render --mode digest <<< "$OVER")
if grep -qF -- "past the free 3,000" <<< "$OD"; then echo "ok: over the allowance says so plainly"
else echo "FAIL: over the allowance is not stated"; echo "$OD"; fail=1; fi
if grep -qE 'run out around|ends near' <<< "$OD"; then
  echo "FAIL: over the allowance still prints a forecast"; echo "$OD"; fail=1
else echo "ok: no forecast once the pool is spent"; fi
OT=$(render --mode table <<< "$OVER")
if grep -qF -- "already past the free 3,000" <<< "$OT"; then echo "ok: the table says it too"
else echo "FAIL: the table still projects past a spent pool"; echo "$OT"; fail=1; fi
# …and a run comfortably inside it still gets its projection.
IN=$(jq -c '.runs = 40 | .free_runs = 0 | .timed = 40 | .minutes = 400' <<< "$FREEONLY")
if grep -qF -- "inside the free pool" <<< "$(render --mode digest <<< "$IN")"; then
  echo "ok: a quiet month still reads as inside the pool"
else echo "FAIL: a quiet month lost its projection"; fail=1; fi

echo "--- 8. the one predicate that decides whether a build is billed at all"
# `_is_free_dependabot_run` moved the account's headline figure (2,550 → 2,515) and had no
# test: `grep -rn free_dependabot bin .github routines` found only the function. If
# GitHub's `event`/`path` shape drifts it silently zeroes real billed minutes, or starts
# charging Kevin for runs GitHub does not — and the only tell would be a number in Slack
# that nobody can check. Loaded the way actions-scan.py loads workflow-hygiene, because
# the filename has a hyphen in it and cannot be imported.
#
# The three run shapes below: Dependabot opening an update pull request (synthesised by
# GitHub, no workflow file, not billed on standard runners); a repo running its OWN tests
# on a Dependabot pull request (an ordinary workflow, and billed — excluding it would
# swing the error the other way); and another synthesised run with nothing to do with
# Dependabot. Then the runner multipliers, including self-hosted, whose minutes are free.
got=$(python3 - <<'PYEOF'
import importlib.util, json, os
spec = importlib.util.spec_from_file_location(
    "scan", os.path.join("bin", "lib", "actions-scan.py"))
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)
runs = [
    {"event": "dynamic", "path": "dynamic/dependabot/dependabot-updates"},
    {"event": "pull_request", "path": ".github/workflows/ci.yml"},
    {"event": "dynamic", "path": "dynamic/pages/pages-build-deployment"},
]
labels = [["ubuntu-latest"], ["windows-latest"], ["macos-14"],
          ["self-hosted", "linux"], []]
print(json.dumps({"free": [scan._is_free_dependabot_run(r) for r in runs],
                  "runners": [list(scan._runner_of(l)) for l in labels]},
                 separators=(",", ":"), sort_keys=True))
PYEOF
)
say "free/billed verdicts, and the runner multipliers" "$got" \
    '{"free":[true,false,false],"runners":[["UBUNTU",1],["WINDOWS",2],["MACOS",10],["SELF",0],["UBUNTU",1]]}'

echo "--- 9. the status word itself, run against a table of cases"
# Until 2026-09-14 this rule lived inline in bin/audit's repo loop and the only way to
# exercise it was to call GitHub forty times — so the column bin/audit calls "the whole
# point of this tool" had no test at all, while the two jq predicates above it had four
# each. It is a function in bin/lib/verdict.sh now, and this is the real one, sourced, not
# a retyped copy. Every branch is pinned, not only the new ones: the extraction has to be
# proved equivalent, and the ORDER of the chain is the logic.
# shellcheck source=bin/lib/verdict.sh
. bin/lib/verdict.sh
#    v <label> <expected>  unreadable is_fork stub approve dependabot manifest auto_merge checks
v() { local label="$1" want="$2"; shift 2; say "$label" "$(verdict "$@")" "$want"; }

v "an unreadable tree beats every other answer" \
  "unknown: could not read this repo's file list (API error or truncated tree)" \
  yes true inline false yes yes "?" "—"
v "a fork is never drift" \
  "fork — upstream's config, leave it alone" \
  no true no true no yes true "—"
v "an unreadable stub is unknown, not inline" \
  "unknown: could not read this repo's merge-rules workflow" \
  no false unreadable true yes yes true ci
v "approve off is drift, stub kind 'yes'" \
  "drift: Actions may not approve pull requests here, so the workflow's approvals will be refused" \
  no false yes false yes yes true ci
v "approve off is drift, stub kind 'source' too" \
  "drift: Actions may not approve pull requests here, so the workflow's approvals will be refused" \
  no false source false yes yes true ci
v "the standards repo knows what it is" \
  "enrolled (this repo IS the standard)" \
  no false source true yes yes true ci
v "a private copy of the merge rules is the drift this exists to end" \
  "drift: still has its own private copy of the merge rules" \
  no false inline true no yes true ci
v "nothing configured, but there is something to update" \
  "security-only" \
  no false no true no yes true "—"
v "nothing configured and nothing to update" \
  "security-only (nothing to update)" \
  no false no true no no true "—"
v "update PRs with nothing to merge them" \
  "drift: gets update PRs but nothing merges them" \
  no false no true yes yes true "—"
v "the full shape" \
  "enrolled" \
  no false yes true yes yes true ci
v "everything but the required check" \
  "drift: no required check, so nothing can safely auto-merge" \
  no false yes true yes yes true "—"
v "everything but the repo switch" \
  "drift: repo setting 'allow auto-merge' is off" \
  no false yes true yes yes false ci
v "the settings call failed, so the switch is unknown and not off" \
  "unknown: could not read this repo's settings" \
  no false yes true yes yes "?" ci

# --- the shape added 2026-09-14: the stub, no dependabot.yml, and that is deliberate.
v "a security-only enrolment is enrolled, not drift" \
  "enrolled (security fixes only)" \
  no false yes true no yes true Vercel
v "…and an external check counts like any other context" \
  "enrolled (security fixes only)" \
  no false yes true no yes true "Vercel, checks"
v "…even on a repo with no app manifest at all" \
  "enrolled (security fixes only)" \
  no false yes true no no true Vercel
# --skip-actions leaves `approve` unreadable. That must not turn a good repo into drift —
# the same absent-versus-false rule the APPROVE_JQ test above pins, one level up.
v "…and an unread approve switch does not demote it" \
  "enrolled (security fixes only)" \
  no false yes "?" no yes true Vercel
# A stub that can merge nothing is still drift, and it gets the MISSING-GATE message, not
# the retired "no dependabot.yml" one — that file is now the intended half, and naming it
# would send Kevin to fix the thing that is not broken.
v "a security-only stub with no gate is still drift" \
  "drift: no required check, so nothing can safely auto-merge" \
  no false yes true no yes true "—"
v "…and the retired wording is really gone" \
  "drift: no required check, so nothing can safely auto-merge" \
  no false yes true no no true "—"
v "a security-only stub with auto-merge off is drift" \
  "drift: repo setting 'allow auto-merge' is off" \
  no false yes true no yes false Vercel
v "a security-only stub whose settings could not be read is unknown" \
  "unknown: could not read this repo's settings" \
  no false yes true no yes "?" Vercel
v "the approve rule still wins over the security-only branch" \
  "drift: Actions may not approve pull requests here, so the workflow's approvals will be refused" \
  no false yes false no yes true Vercel

# --- the overlapping cases, where the ORDER of the chain is the only thing deciding.
# Every case above sets one condition at a time, and that is exactly how an ordering bug
# survives: Codex swapped the fork branch with the unreadable-stub branch and nothing
# noticed, because no case was both at once.
v "a fork whose stub is unreadable is still a fork" \
  "fork — upstream's config, leave it alone" \
  no true unreadable true yes yes true ci
v "an unreadable tree beats a fork" \
  "unknown: could not read this repo's file list (API error or truncated tree)" \
  yes true unreadable false yes yes "?" "—"
v "a fork beats the approve-switch rule" \
  "fork — upstream's config, leave it alone" \
  no true yes false yes yes true ci
v "an unreadable stub beats the approve-switch rule" \
  "unknown: could not read this repo's merge-rules workflow" \
  no false unreadable false yes yes true ci
v "the standards repo is not demoted by a missing gate" \
  "enrolled (this repo IS the standard)" \
  no false source true yes yes false "—"

# --- and the FULL mapping, pinned as a checked-in fixture.
# The first version of this asserted only the SET of words the rule can produce (`sort -u`),
# which throws away which input produced which answer — and Codex proved that hole by
# swapping two branches with the whole suite still green. The order of an if/elif chain is
# its logic, so all 1,440 input -> output lines are pinned. Regenerate deliberately with
# `bin/lib/verdict-matrix.sh > bin/lib/fixtures/audit/verdict-matrix.txt`, READ the diff,
# then commit it; a regenerated fixture nobody read is the same as no fixture at all.
MATRIX=bin/lib/fixtures/audit/verdict-matrix.txt
if diff -u "$MATRIX" <(bin/lib/verdict-matrix.sh) > "$TMPDIFF"; then
  echo "ok: all $(grep -cv '^#' "$MATRIX") input combinations map to their pinned status word"
else
  echo "FAIL: the verdict rule's input -> output mapping changed"
  head -40 "$TMPDIFF" | sed 's/^/     /'
  echo "     (if the change is intended: bin/lib/verdict-matrix.sh > $MATRIX, read the diff, commit it)"
  fail=1
fi
# …and the alphabet, read off the pinned matrix rather than swept again. It is the sentence
# a human can check: the renderer switches on `startswith`, so a status word it has never
# seen is not an error — it is silently counted as drift in the weekly digest.
# grep -v '^#' first: the fixture's two header lines end in "-> status", and counting them
# as data is how this very assertion first read "15 distinct status words" and "1441
# combinations". Caught by running it, 2026-09-14.
alphabet=$(grep -v '^#' "$MATRIX" | sed -n 's/.* -> //p' | sort -u | wc -l | tr -d ' ')
say "the rule produces exactly 14 distinct status words" "$alphabet" "14"
if grep -qF "merge rules but no dependabot.yml" "$MATRIX"; then
  echo "FAIL: the retired 'merge rules but no dependabot.yml' verdict is reachable again"; fail=1
else
  echo "ok: the retired no-dependabot.yml verdict is unreachable, not merely unused"
fi

echo "--- 9b. the --external-check evidence rule, pinned the same way"
# This one was an inline if/elif chain in bin/enroll for about an hour, and in that hour a
# branch added at the top shadowed every recency case below it: a check that had stopped
# firing on Dependabot's newest branch still enrolled cleanly on month-old evidence. Caught
# by a simulated run, not by reading — which is the argument for pinning it here.
# shellcheck source=bin/lib/check-evidence.sh
. bin/lib/check-evidence.sh
e() { local label="$1" want="$2"; shift 2; say "$label" "$(evidence_verdict "$@")" "$want"; }
#   e <label> <expected>   bot_proof bot_read bot_newest_ok bot_missing bot_seen allow
e "newest bot PR carries it, none missing"      accept-bot            "PR #1" 2 yes 0 2 ""
e "newest carries it, an older one does not"    accept-bot-older-gap  "PR #1" 2 yes 1 2 ""
e "newest does NOT carry it — refused"          refuse-newest         "PR #9" 2 no  1 2 ""
e "…even when no bot PR ever carried it"        refuse-newest         ""      1 no  1 1 ""
e "…unless the operator overrides deliberately" accept-override       "PR #9" 2 no  1 2 "1"
e "bot PRs exist but none could be read"        accept-unread-bot     ""      0 ""  0 2 ""
e "no bot PR in the sample at all"              accept-no-bot         ""      0 ""  0 0 ""
e "an override does not rescue an unread answer" accept-unread-bot    ""      0 ""  0 2 "1"
e "an override does not invent bot evidence"    accept-no-bot         ""      0 ""  0 0 "1"

EMATRIX=bin/lib/fixtures/audit/evidence-matrix.txt
if diff -u "$EMATRIX" <(bin/lib/evidence-matrix.sh) > "$TMPDIFF"; then
  echo "ok: all $(grep -cv '^#' "$EMATRIX") evidence combinations map to their pinned verdict"
else
  echo "FAIL: the evidence rule's input -> output mapping changed"
  head -30 "$TMPDIFF" | sed 's/^/     /'
  echo "     (if intended: bin/lib/evidence-matrix.sh > $EMATRIX, read the diff, commit it)"
  fail=1
fi
# The one invariant worth stating in words: a readable Dependabot pull request that does not
# carry the check can only ever end in refusal or a deliberate override. Never a quiet yes.
bad=$(grep -v '^#' "$EMATRIX" | awk '$2 > 0 && $3 == "no"' | grep -vE '\-> (refuse-newest|accept-override)$' || true)
if [ -z "$bad" ]; then
  echo "ok: a readable bot PR missing the check never yields a quiet acceptance"
else
  echo "FAIL: some combination accepts despite the newest bot PR missing the check"
  printf '%s\n' "$bad" | sed 's/^/     /'; fail=1
fi

echo "--- 10. the security-only enrolment through all three renderings"
# It must read as ENROLLED (the repo is handled — its security fixes merge themselves) and
# the parenthetical must survive, because "keeps itself up to date" alone overstates a repo
# that takes no routine version bumps at all. Three rows: one of each shape.
SEC='{"name":"ynai","visibility":"PRIVATE","pushed":"2026-09-14","manifest":"yes",
 "dependabot":"no","stub":"yes","auto_merge":"true","checks":"Vercel","prs":"0",
 "pr_count":0,"pr_oldest_days":null,"approve":true,"approve_cell":"true","minutes":100,
 "runs":20,"free_runs":0,"timed":20,"capped":false,"runners":["UBUNTU"],
 "missing_timeout":[],"double_trigger":[],"unparsed":[],"parser":"pyyaml","errors":[],
 "is_fork":false,"status":"enrolled (security fixes only)"}'
FULL=$(jq -c '.name="eachie" | .dependabot="yes" | .checks="unit" | .status="enrolled"' <<< "$SEC")
HALF=$(jq -c '.name="wkt" | .checks="—"
              | .status="drift: no required check, so nothing can safely auto-merge"' <<< "$SEC")
THREE=$(printf '%s\n%s\n%s\n' "$(jq -c . <<< "$SEC")" "$FULL" "$HALF")

ST=$(render --mode table <<< "$THREE")
if grep -qF -- "**2 enrolled** (1 for security fixes only), 0 security-only" <<< "$ST"; then
  echo "ok: the table counts it as enrolled and says which kind"
else echo "FAIL: the table's summary hides the security-only enrolment"; echo "$ST"; fail=1; fi
if grep -qF -- "| enrolled (security fixes only) |" <<< "$ST"; then
  echo "ok: the row carries the status word"
else echo "FAIL: the table row lost the status word"; fail=1; fi
if grep -qF -- "no routine version_" <<< "$ST"; then
  echo "ok: the table legend explains the new word"
else echo "FAIL: the table legend does not explain the new status"; fail=1; fi

SJ=$(render --mode json <<< "$THREE")
say "json: two enrolled"                  "$(jq -r '.summary.enrolled' <<< "$SJ")" "2"
say "json: one of them security-only"     "$(jq -r '.summary.enrolled_security_only' <<< "$SJ")" "1"
say "json: none counted as security-only" "$(jq -r '.summary.security_only' <<< "$SJ")" "0"
say "json: one drifting"                  "$(jq -r '.summary.drifting' <<< "$SJ")" "1"

SD=$(render --mode digest <<< "$THREE")
if grep -qF -- "2 of 3 repos keep themselves up to date (1 for security fixes only)" <<< "$SD"; then
  echo "ok: the digest headline says it plainly"
else echo "FAIL: the digest headline overstates or loses the count"; echo "$SD"; fail=1; fi
if grep -qF -- "- wkt — no required check" <<< "$SD"; then
  echo "ok: the half-set-up one still gets its own line"
else echo "FAIL: the drifting repo lost its digest line"; echo "$SD"; fail=1; fi
# A repo that IS fully enrolled must not be quietly described as security-only, so the
# parenthetical has to be absent when nothing earns it.
NOSEC=$(printf '%s\n%s\n' "$FULL" "$HALF")
for m in table digest; do
  if grep -qF -- "for security fixes only" <<< "$(render --mode "$m" <<< "$NOSEC")"; then
    echo "FAIL: the $m claims a security-only enrolment where there is none"; fail=1
  else echo "ok: the $m says nothing about security-only when no repo is"; fi
done
# …and the whole message still fits, with the extra words in the headline. Twice: on the
# three-row fixture, and at ACCOUNT SIZE, which is where the cap actually bites. The cap
# loop gives up repo lines until the message fits, but it stops at zero repo lines — so a
# headline plus notes that alone exceed 150 words would run over in silence, and this
# parenthetical made that margin five words narrower.
cap_words "with a security-only enrolment" "$SD"
WIDE_SEC=$(python3 -c 'import json
rows = [json.loads(l) for l in open("bin/lib/fixtures/audit/rows-wide.jsonl") if l.strip()]
n = 0
for r in rows:
    if r["status"] == "enrolled" and n < 3:
        r["status"] = "enrolled (security fixes only)"; r["dependabot"] = "no"; n += 1
print("\n".join(json.dumps(r) for r in rows))' | render --mode digest)
cap_words "account-sized with three security-only enrolments" "$WIDE_SEC"
if grep -qF -- "(3 for security fixes only)" <<< "$WIDE_SEC"; then
  echo "ok: the parenthetical survives the account-sized trim"
else echo "FAIL: the parenthetical was trimmed away at account size"; echo "$WIDE_SEC"; fail=1; fi

exit "$fail"
