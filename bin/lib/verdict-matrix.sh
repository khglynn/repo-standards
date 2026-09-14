#!/usr/bin/env bash
# Print the FULL input -> output mapping of bin/lib/verdict.sh: one line per combination of
# its eight inputs, 1,440 of them.
#
#   bin/lib/verdict-matrix.sh > bin/lib/fixtures/audit/verdict-matrix.txt   # regenerate
#
# WHY A WHOLE MATRIX AND NOT A SET OF ANSWERS (2026-09-14, Codex review). The first version
# of this test swept the same 1,440 combinations and asserted the SET of status words the
# rule can produce — `sort -u`, which throws away which input produced which answer. Codex
# swapped the fork branch and the unreadable-stub branch and the entire suite still passed,
# because no named case covered a repo that is BOTH a fork and has an unreadable stub: the
# vocabulary was unchanged, the answers were not. The order of an if/elif chain IS its
# logic, and only a full mapping pins it.
#
# So the fixture is checked in, and any edit to the rule shows up as a diff of exactly the
# combinations whose answer moved. Regenerate it deliberately, read the diff, and only then
# commit it — a regenerated fixture nobody read is the same as no fixture.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=bin/lib/verdict.sh
. "$HERE/bin/lib/verdict.sh"

echo "# bin/lib/verdict.sh, every input combination. Regenerate: bin/lib/verdict-matrix.sh"
echo "# columns: unreadable is_fork stub approve dependabot manifest auto_merge checks -> status"
for unreadable in yes no; do
  for is_fork in true false; do
    for stub in yes no source inline unreadable; do
      for approve in true false "?"; do
        for dependabot in yes no; do
          for manifest in yes no; do
            for auto_merge in true false "?"; do
              for checks in ci "—"; do
                printf '%s %s %s %s %s %s %s %s -> %s\n' \
                  "$unreadable" "$is_fork" "$stub" "$approve" "$dependabot" \
                  "$manifest" "$auto_merge" "$checks" \
                  "$(verdict "$unreadable" "$is_fork" "$stub" "$approve" \
                             "$dependabot" "$manifest" "$auto_merge" "$checks")"
              done; done; done; done; done; done; done; done
