#!/usr/bin/env bash
# Prove the two copies of the classification rule still agree, and that the trailer parser
# reproduces fetch-metadata's COMPUTED update-type.
#
# WHY TWO COPIES EXIST AT ALL: the shared workflow never checks out any code (that is what
# makes `pull_request_target` safe), so it cannot read a shared .jq file — the program has
# to be inline. bin/classify-pr therefore carries a second copy. Duplication that cannot be
# removed has to be policed instead, which is this script's whole job. Run by CI.
#
# Written 2026-09-11, after a review found bin/classify-pr predicting `dependabot-needs-
# human` for eachie #116 where the workflow would say `major-review-needed` — because the
# tool read the raw trailer and the action computes a fallback from the versions.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$HERE"
fail=0
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- 1. the two jq programs
# Pulled out by their shared first line, which is the rule's actual signature.
# shellcheck disable=SC2016  # the $t below is part of the jq program's own syntax, not a shell variable
# The trailing `')` or `'` is the shell quoting around the program, not part of it.
extract() { sed -n '/\[\.\[\] | \.updateType\] as \$t/,/else "disallowed" end/p' "$1" \
              | sed -e "s/')[[:space:]]*$//" -e "s/'[[:space:]]*$//" -e 's/^[[:space:]]*//'; }
extract .github/workflows/dependabot-automerge.yml > "$WORK/jq-workflow.jq"
extract bin/classify-pr                            > "$WORK/jq-tool.jq"
if [ ! -s "$WORK/jq-workflow.jq" ] || [ ! -s "$WORK/jq-tool.jq" ]; then
  echo "FAIL: could not find the classification jq in one of the two files — did it get renamed?"
  fail=1
elif ! diff -u "$WORK/jq-workflow.jq" "$WORK/jq-tool.jq"; then
  echo "FAIL: the workflow and bin/classify-pr no longer classify the same way."
  echo "      They are two copies of ONE rule. Change both, or the tool starts lying."
  fail=1
else
  echo "ok: the workflow and bin/classify-pr carry the same classification rule"
fi

# ------------------------------------- 2. a null update-type must be COMPUTED, not unknown
# This is the eachie #116 shape verbatim: no `update-type` in the trailer, versions only in
# the human-readable "Bumps … from A to B." line. fetch-metadata v3 computes major here.
# Reading the trailer alone would say "unknown", and — the dangerous direction — a
# 1.2.3 → 1.2.4 bump of the same shape would say "unknown" while the workflow MERGES it.
check_computed() {
  local label="$1" from="$2" to="$3" want="$4" got
  got=$(printf 'Bumps [ai](https://example.invalid) from %s to %s.\n\n---\nupdated-dependencies:\n- dependency-name: ai\n  dependency-version: %s\n  dependency-type: direct:production\n...\n' \
          "$from" "$to" "$to" \
        | python3 bin/lib/trailer-to-json.py --branch "dependabot/npm_and_yarn/ai-$to" --title "bump ai from $from to $to" \
        | jq -r '.[0].updateType')
  if [ "$got" = "$want" ]; then
    echo "ok: $label ($from → $to) computes as $want"
  else
    echo "FAIL: $label ($from → $to) computed '$got', expected '$want'"
    fail=1
  fi
}
check_computed "null update-type, major"  "4.3.19" "5.0.52" "version-update:semver-major"
check_computed "null update-type, minor"  "1.2.3"  "1.3.0"  "version-update:semver-minor"
check_computed "null update-type, patch"  "1.2.3"  "1.2.4"  "version-update:semver-patch"

# ------------------------------ 3. and that computed type reaches the same verdict as the
#                                   workflow's jq, rather than stopping at "unknown".
# Runs the WORKFLOW's own extracted program — not a retyped copy of it — so a rule change
# without a fixture change shows up here as a failing expectation.
run_rule() {
  jq -r --argjson allowed '["version-update:semver-patch","version-update:semver-minor"]' \
        --argjson known '["version-update:semver-patch","version-update:semver-major","version-update:semver-minor"]' \
        -f "$WORK/jq-workflow.jq"
}
verdict=$(printf '[{"updateType":"version-update:semver-patch"},{"updateType":null}]' | run_rule)
if [ "$verdict" = "unknown" ]; then
  echo "ok: patch + a genuinely null type still stops as 'unknown'"
else
  echo "FAIL: patch + null gave '$verdict', expected 'unknown'"
  fail=1
fi
verdict=$(printf '[{"updateType":"version-update:semver-patch"},{"updateType":"version-update:semver-minor"}]' | run_rule)
if [ "$verdict" = "merge" ]; then
  echo "ok: patch + minor merges"
else
  echo "FAIL: patch + minor gave '$verdict', expected 'merge'"
  fail=1
fi
verdict=$(printf '[{"updateType":"version-update:semver-patch"},{"updateType":"version-update:semver-major"}]' | run_rule)
if [ "$verdict" = "major" ]; then
  echo "ok: patch + major stops as 'major'"
else
  echo "FAIL: patch + major gave '$verdict', expected 'major'"
  fail=1
fi

exit "$fail"
