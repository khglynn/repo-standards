#!/usr/bin/env bash
# The decision `bin/enroll --external-check` makes once it has looked at the history:
# given what the five most recent pull requests showed, is this check proven enough to be
# made a required gate?
#
#   evidence_verdict <bot_proof> <bot_read> <bot_newest_ok> <bot_missing> <bot_seen> <allow>
#
# Prints ONE token. The wording lives in bin/enroll; only the decision lives here.
#
#   accept-bot            the newest readable Dependabot PR carried the check, and so did
#                         every other readable one. The real proof.
#   accept-bot-older-gap  the newest readable Dependabot PR carried it, some older one did
#                         not — the signature of an integration switched on at some point.
#   accept-override       the newest readable Dependabot PR did NOT carry it, and the
#                         operator said so deliberately (ALLOW_UNPROVEN_CHECK=1).
#   refuse-newest         the newest readable Dependabot PR did not carry it. Whether an
#                         older one did or none did, this is a check that is not reporting
#                         on Dependabot's branches TODAY.
#   accept-unread-bot     there were Dependabot PRs but none of their heads could be read:
#                         an unread answer, not a good one.
#   accept-no-bot         no Dependabot PR in the sample at all: nothing proves the check
#                         fires on a dependabot/* branch, and nothing disproves it.
#
# WHY THIS IS A FUNCTION IN ITS OWN FILE (2026-09-14). It was an inline if/elif chain, and
# within an hour of writing it the session added a `bot_proof` branch ABOVE the recency
# branches — which shadowed all of them, so a check that had stopped firing on Dependabot's
# newest branch still enrolled cleanly on month-old evidence. It was caught by a simulated
# run, not by reading. That is the second ordering bug in one afternoon in this repo (see
# bin/lib/verdict.sh), and the answer is the same: extract it, and pin the whole mapping.
#
# ORDER IS THE LOGIC. bin/lib/check-audit.sh runs every combination against the fixture
# bin/lib/fixtures/audit/evidence-matrix.txt.

# shellcheck shell=bash

evidence_verdict() {
  local bot_proof="$1" bot_read="$2" bot_newest_ok="$3" bot_missing="$4" \
        bot_seen="$5" allow="$6"
  # bot_proof is not consulted for the decision — only for the wording of a refusal — but
  # it is taken as an argument so a future edit cannot quietly start depending on a global.
  : "$bot_proof"

  if [ "$bot_read" -gt 0 ]; then
    # At least one Dependabot pull request's head was actually read, so there is a real
    # answer about Dependabot's branches, and the NEWEST one is the one that speaks to today.
    if [ "$bot_newest_ok" = "yes" ]; then
      if [ "$bot_missing" -eq 0 ]; then
        printf 'accept-bot\n'
      else
        printf 'accept-bot-older-gap\n'
      fi
    elif [ "$allow" = "1" ]; then
      printf 'accept-override\n'
    else
      printf 'refuse-newest\n'
    fi
  elif [ "$bot_seen" -gt 0 ]; then
    printf 'accept-unread-bot\n'
  else
    printf 'accept-no-bot\n'
  fi
}
