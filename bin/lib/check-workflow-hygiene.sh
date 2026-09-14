#!/usr/bin/env bash
# Fixture tests for bin/lib/workflow-hygiene.py — the two warnings `bin/audit` reports
# about other people's workflows. Run by CI.
#
# WHY THESE EXIST: the parser's answers arrive in a weekly Slack digest that Kevin reads
# and acts on. A parser that quietly starts saying "no problems" is indistinguishable,
# from the digest, from a month where nothing was wrong. Fixtures are the only thing that
# can tell those two apart. Written 2026-09-14.
#
# Each fixture carries its own expectation as a comment at the top of the file; this
# script is the machine-readable half of the same statement.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$HERE"
FIX="bin/lib/fixtures/workflow-hygiene"
fail=0

scan() { python3 bin/lib/workflow-hygiene.py --default-branch main "$FIX/$1"; }

expect() {
  local file="$1" field="$2" want="$3" got
  got=$(scan "$file" | jq -c ".$field")
  if [ "$got" = "$want" ]; then
    echo "ok: $file .$field = $want"
  else
    echo "FAIL: $file .$field = $got, expected $want"
    fail=1
  fi
}

echo "--- (c) jobs without timeout-minutes"
expect timeouts-present.yml            missing_timeout '[]'
expect timeouts-missing.yml            missing_timeout '["timeouts-missing.yml:unit"]'
# The exclusion that keeps this check usable at all: a reusable-workflow caller cannot
# legally carry timeout-minutes, and every enrolled repo has one.
expect reusable-caller.yml             missing_timeout '[]'

echo "--- (d) the double trigger"
expect double-trigger-all-branches.yml   double_trigger '["double-trigger-all-branches.yml"]'
expect double-trigger-list-form.yml      double_trigger '["double-trigger-list-form.yml"]'
expect double-trigger-branches-ignore.yml double_trigger '["double-trigger-branches-ignore.yml"]'
# push restricted to the default branch is the CORRECT shape and must stay silent,
# otherwise the warning fires on this repo's own ci.yml and gets tuned out.
expect single-trigger-default-branch.yml double_trigger '[]'
# push-on-tags + pull_request is not a double run. The naive check gets this wrong.
expect single-trigger-tags-only.yml      double_trigger '[]'

echo "--- an unreadable file reads as unknown, never as clean"
expect malformed.yml unparsed        '["malformed.yml"]'
expect malformed.yml missing_timeout '[]'
expect malformed.yml double_trigger  '[]'

echo "--- the regex fallback (hosts without PyYAML — the weekly digest may run on one)"
# It answers the timeout question and DECLINES the trigger question rather than guessing,
# so `double_trigger` is empty by design on this path. `bin/audit` prints which parser ran.
got=$(WORKFLOW_HYGIENE_NO_YAML=1 python3 bin/lib/workflow-hygiene.py --default-branch main \
        "$FIX/timeouts-missing.yml" | jq -c '[.parser, .missing_timeout]')
if [ "$got" = '["regex",["timeouts-missing.yml:unit"]]' ]; then
  echo "ok: regex fallback finds the same missing timeout"
else
  echo "FAIL: regex fallback gave $got"
  fail=1
fi
got=$(WORKFLOW_HYGIENE_NO_YAML=1 python3 bin/lib/workflow-hygiene.py --default-branch main \
        "$FIX/double-trigger-all-branches.yml" | jq -c '.double_trigger')
if [ "$got" = '[]' ]; then
  echo "ok: regex fallback declines the trigger question instead of guessing"
else
  echo "FAIL: regex fallback claimed to answer the trigger question: $got"
  fail=1
fi

exit "$fail"
