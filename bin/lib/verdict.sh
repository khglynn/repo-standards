#!/usr/bin/env bash
# The one function that decides what `bin/audit` says about a repo.
#
#   verdict <unreadable> <is_fork> <has_stub> <approve> <has_dependabot> <has_manifest> \
#           <auto_merge> <checks>
#
# It is a pure function of eight strings and prints one status line. Nothing here calls
# the network, so `bin/lib/check-audit.sh` can run the REAL rule against a table of cases
# rather than a retyped copy of it.
#
# WHY IT LIVES IN ITS OWN FILE (2026-09-14). This chain is, in bin/audit's own words, "the
# whole point of this tool" — and until today it sat inline inside the repo loop, where the
# only way to exercise it was to call GitHub forty times. Every bug this repo has caught in
# itself has been a confident answer nobody could test: `.truncated // "err"` printed a
# full table of lies for three days, and `.approve // "?"` turned the one value a drift
# rule looked for into "unknown". Adding a ninth branch to an untested chain would have
# been the same bet a fourth time.
#
# ORDER IS THE LOGIC. Each branch assumes every branch above it already failed, so moving
# one changes answers elsewhere. The comments say what each one is protecting.

# shellcheck shell=bash

verdict() {
  local unreadable="$1" is_fork="$2" has_stub="$3" approve="$4" \
        has_dependabot="$5" has_manifest="$6" auto_merge="$7" checks="$8"
  local status

  # A fork's dependabot.yml belongs to whoever we forked FROM. Enrolling one means fighting
  # upstream on every sync, so a fork is never drift — it is just not ours to standardise.
  if [ "$unreadable" = "yes" ]; then
    status="unknown: could not read this repo's file list (API error or truncated tree)"
  elif [ "$is_fork" = "true" ]; then
    status="fork — upstream's config, leave it alone"
  elif [ "$has_stub" = "unreadable" ]; then
    status="unknown: could not read this repo's merge-rules workflow"
  elif { [ "$has_stub" = "yes" ] || [ "$has_stub" = "source" ]; } && [ "$approve" = "false" ]; then
    # The switch whose absence stranded three list-maker PRs on 2026-09-14: the shared
    # workflow's `gh pr review --approve` is refused outright, so in any repo with a
    # one-approval rule the PR queues behind a review that can never arrive.
    status="drift: Actions may not approve pull requests here, so the workflow's approvals will be refused"
  elif [ "$has_stub" = "source" ] && [ "$has_dependabot" = "yes" ]; then
    status="enrolled (this repo IS the standard)"
  elif [ "$has_stub" = "inline" ]; then
    status="drift: still has its own private copy of the merge rules"
  elif [ "$has_dependabot" = "no" ] && [ "$has_stub" = "no" ]; then
    if [ "$has_manifest" = "yes" ]; then
      status="security-only"
    else
      status="security-only (nothing to update)"
    fi
  elif [ "$has_dependabot" = "yes" ] && [ "$has_stub" = "no" ]; then
    status="drift: gets update PRs but nothing merges them"
  elif [ "$has_stub" = "yes" ] && [ "$has_dependabot" = "no" ]; then
    # THE SECURITY-ONLY ENROLMENT (added 2026-09-14, with `bin/enroll --security-only`).
    #
    # This combination used to read `drift: merge rules but no dependabot.yml, so no update
    # PRs` — a fault on its face. It is now a deliberate, supported shape: no dependabot.yml
    # means no routine version bumps, and GitHub's account-wide security fixes still arrive
    # and now merge themselves behind the required check. About 29 of Kevin's repos are
    # candidates, several of them gated on a Vercel or Cloudflare build rather than on CI.
    #
    # It only counts as enrolled when the rest of the machinery is really there, so the same
    # three settings the full `enrolled` verdict demands are demanded here, in the same
    # order and in the same words. (The approve switch was already checked above, for both
    # stub kinds at once.)
    #
    # A stub with no required check is STILL DRIFT — merge rules that can merge nothing —
    # and it gets the missing-gate message the full path already uses, not the old
    # no-dependabot.yml one. That wording is retired on purpose: the missing file is now the
    # intended half, and naming it would send Kevin to fix the thing that is not broken.
    if [ "$auto_merge" = "?" ]; then
      status="unknown: could not read this repo's settings"
    elif [ "$auto_merge" != "true" ]; then
      status="drift: repo setting 'allow auto-merge' is off"
    elif [ "$checks" = "—" ]; then
      status="drift: no required check, so nothing can safely auto-merge"
    else
      status="enrolled (security fixes only)"
    fi
  elif [ "$auto_merge" = "?" ]; then
    # The repo call failed, so the setting was never read. Reporting the switch as OFF
    # here would be the same shape as the stub bug above, and it lands on the repos that
    # got everything else right — only a repo with both the stub and dependabot.yml
    # reaches this line at all.
    status="unknown: could not read this repo's settings"
  elif [ "$auto_merge" != "true" ]; then
    status="drift: repo setting 'allow auto-merge' is off"
  elif [ "$checks" = "—" ]; then
    status="drift: no required check, so nothing can safely auto-merge"
  else
    status="enrolled"
  fi

  printf '%s\n' "$status"
}
