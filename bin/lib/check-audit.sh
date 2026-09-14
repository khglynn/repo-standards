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
# Written 2026-09-14.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$HERE"
fail=0

say() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2', wanted '$3'"; fail=1; fi; }

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
DIGEST=$(python3 bin/lib/render-audit.py --mode digest --owner khglynn --since 2026-09-01 < "$FIX")

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
has "6 update pull requests waiting, the oldest 26 days old"
has "about 1000 minutes of the free 3,000"
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

# The capped-run caveat has to survive, or the minutes silently read low.
has "had more runs this month than were measured"
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
  D=$(python3 bin/lib/render-audit.py --mode digest --owner khglynn --since 2026-09-01 \
        --method "$meth" < "$UNMEAS")
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

  T=$(python3 bin/lib/render-audit.py --mode table --owner khglynn --since 2026-09-01 \
        --method "$meth" < "$UNMEAS")
  if grep -qF -- "NOT MEASURED on this run" <<< "$T"; then echo "ok: table ($meth) says not measured"
  else echo "FAIL: table ($meth) does not say not measured"; fail=1; fi
  if grep -qE 'Private repos: \*\*[0-9]' <<< "$T"; then echo "FAIL: table ($meth) still prints a private-minutes figure"; fail=1
  else echo "ok: table ($meth) prints no private-minutes figure"; fi

  J=$(python3 bin/lib/render-audit.py --mode json --owner khglynn --since 2026-09-01 \
        --method "$meth" < "$UNMEAS")
  say "json ($meth) minutes_measured is false" "$(jq -r '.minutes_measured' <<< "$J")" "false"
  say "json ($meth) private minutes are null"  "$(jq -r '.minutes.private' <<< "$J")" "null"
  say "json ($meth) projection is null"        "$(jq -r '.minutes.projected' <<< "$J")" "null"
done

# And the measured path must keep saying a real number, or the fix above has gone too far.
say "a measured run still reports minutes" \
    "$(python3 bin/lib/render-audit.py --mode json --owner khglynn --since 2026-09-01 \
        --method jobs < "$FIX" | jq -r '.minutes.private')" "1000"

exit "$fail"
