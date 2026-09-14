#!/usr/bin/env bash
# Print the full input -> output mapping of bin/lib/check-evidence.sh.
#   bin/lib/evidence-matrix.sh > bin/lib/fixtures/audit/evidence-matrix.txt
# See bin/lib/verdict-matrix.sh for why the mapping is pinned and not just the vocabulary.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=bin/lib/check-evidence.sh
. "$HERE/bin/lib/check-evidence.sh"
echo "# bin/lib/check-evidence.sh, every input combination."
echo "# columns: bot_proof bot_read bot_newest_ok bot_missing bot_seen allow -> verdict"
# bot_proof is printed as a single unambiguous token, never its real value: it has a SPACE
# in it ("PR #14"), which shifted every awk column and left the invariant assertion in
# check-audit.sh examining only the empty-proof half of the rows (third Codex review,
# 2026-09-14). Its value never changes the decision anyway — only whether it is set.
#
# The ranges are a superset of what bin/enroll can reach (it samples at most 5 pull
# requests, so every counter tops out at 5) with room for the boundaries that matter, and
# `allow` includes near-miss values because the rule wants EXACTLY "1".
for bot_proof in "" "PR #14"; do
  for bot_read in 0 1 2 3; do
    for bot_newest_ok in yes no ""; do
      for bot_missing in 0 1 2; do
        for bot_seen in 0 1 2 3; do
          for allow in 1 0 true ""; do
            printf '%s %s %s %s %s %s -> %s\n' \
              "$( [ -n "$bot_proof" ] && echo set || echo none )" "$bot_read" "${bot_newest_ok:-unset}" \
              "$bot_missing" "$bot_seen" "${allow:-unset}" \
              "$(evidence_verdict "$bot_proof" "$bot_read" "$bot_newest_ok" \
                                  "$bot_missing" "$bot_seen" "$allow")"
          done; done; done; done; done; done
