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

# The timeout question is asked of BOTH parsers, every fixture, because the two paths
# disagreed for a day and only one of them is the one a cloud routine takes. On
# 2026-09-14 the regex fallback answered `[]` for the two fixtures below — a job whose
# STEPS carry `uses:` (which it read as a reusable-workflow caller) and a job whose only
# `timeout-minutes:` is on a step (which caps the step, not the job). Between them that
# is most real workflows, so the digest would have said "no repos have this problem"
# forever. Testing one parser per fixture is what let that through.
expect_both() {
  local file="$1" want="$2" got
  for engine in pyyaml regex; do
    if [ "$engine" = regex ]; then
      got=$(WORKFLOW_HYGIENE_NO_YAML=1 python3 bin/lib/workflow-hygiene.py \
              --default-branch main "$FIX/$file" | jq -c '.missing_timeout')
    else
      got=$(scan "$file" | jq -c '.missing_timeout')
    fi
    if [ "$got" = "$want" ]; then
      echo "ok: $file ($engine) missing_timeout = $want"
    else
      echo "FAIL: $file ($engine) missing_timeout = $got, expected $want"
      fail=1
    fi
  done
}

echo "--- (c) jobs without timeout-minutes — every fixture through both parsers"
expect_both timeouts-present.yml  '[]'
expect_both timeouts-missing.yml  '["timeouts-missing.yml:unit"]'
# The exclusion that keeps this check usable at all: a reusable-workflow caller cannot
# legally carry timeout-minutes, and every enrolled repo has one.
expect_both reusable-caller.yml   '[]'
# …and the exclusion must not spread to a job that merely CONTAINS a `uses:` step, which
# is how most jobs are written.
expect_both steps-with-uses.yml   '["steps-with-uses.yml:unit"]'
# A step-level timeout caps that step only. The job still inherits the six-hour default.
expect_both step-level-timeout.yml '["step-level-timeout.yml:unit"]'

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
  echo "ok: regex fallback names itself and finds the same missing timeout"
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
