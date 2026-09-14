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
for bot_proof in "" "PR #14"; do
  for bot_read in 0 1 2; do
    for bot_newest_ok in yes no ""; do
      for bot_missing in 0 1; do
        for bot_seen in 0 1 2; do
          for allow in 1 ""; do
            printf '%s %s %s %s %s %s -> %s\n' \
              "${bot_proof:-(none)}" "$bot_read" "${bot_newest_ok:-(unset)}" \
              "$bot_missing" "$bot_seen" "${allow:-(unset)}" \
              "$(evidence_verdict "$bot_proof" "$bot_read" "$bot_newest_ok" \
                                  "$bot_missing" "$bot_seen" "$allow")"
          done; done; done; done; done; done
