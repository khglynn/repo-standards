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

exit "$fail"
