# NOW — dependabot-verdicts arc (arc mode)
last-updated: 2026-09-14 08:12 CDT · mode: arc · read GROUNDING.md first
(Clock note: stamps elsewhere in this folder that say "00:2x CT" were written two hours early; those events happened at 02:2x CDT, per the machine clock and commit times.)

## State (overnight 2026-09-13 → 09-14, unattended)
- Four repos enrolled and proven live (eachie, festival-navigator, kevinhg-com, list-maker). Four verdict routines live on kevn.hg@gmail.com (ids in `routines/dependabot-verdict.md`).
- 02:27 Codex's four fixes to the approve step landed (f321bef). 08:03 the shared workflow's automerge job got `timeout-minutes: 10` (f1be915) — the audit's first finding was the one job with write permission everywhere having no ceiling.
- 02:33 The FINAL verdict shape observed on a real PR (eachie #161, "Merge after a fix. Risk: medium."). Acceptance 4 met.
- 03:09 The overnight builder died on the usage limit with everything committed; resumed 06:56 as a four-stage workflow (finish → Opus review → fix → Sonnet verify), done 07:58: nine MUST-FIX defects found and fixed (three more "confident zero" doors, a regex parser that found nothing on normal workflows, a CI fixture that would have started failing 27 Sep, two failed-read-reported-as-drift bugs, a past run-out date printed as future, the 150-word cap now enforced by the renderer), CI green on every commit, verify clean. Acceptance 5 (the audit half) met.
- 07:01 "Dependabot weekly digest" routine created and run once (`trig_01TTfxzWdWUA3J9PGPP6w6ap`, Monday 08:00 CT). Finding: the cloud sandbox has NO `gh`, so the routine can never run the audit itself; it posted an honest fallback. Fix shipped 08:03: `.github/workflows/weekly-audit.yml` runs the audit on GitHub's runners every Monday and writes `latest-digest.md` to the `audit-output` branch; the routine (live instructions updated 08:08) reads that file first. The job needs the `AUDIT_READ_TOKEN` secret from Kevin (below); until then it fails at step one and says so. The 08:00 scheduled run did not fire today (the page shows next run Sep 21); the 07:01 manual run may have counted. Watch next Monday.
- Codex review of the 08:03 follow-up: running at the time of this stamp (`cx-20260914-080434-78451-2639b8`).

## The real numbers this morning (bin/audit, full run 07:53 CDT)
5 of 40 repos keep themselves up to date · 12 Dependabot PRs waiting (ynai 4, recordOS 3, eachie 2, three repos with 1) · private-repo build minutes about 2,453 of the free 3,000, on course to run out around 16 Sep (estimate; eachie read low) · 27 jobs in 11 repos with no time limit · 4 repos run tests twice per change.

## Exact next step
F: morning report in chat + hg-agents memo + Notion /save-session. Then wait for Kevin on the items below. Next Monday: confirm the weekly-audit job ran and the routine posted the file (or the fallback, if the secret is still missing).

## For Kevin (self-contained)
1. Mint the read-only token so the weekly audit can run (two minutes, one time a year): github.com/settings/personal-access-tokens/new → name `repo-standards weekly audit`, expiration 1 year, resource owner khglynn, repository access "All repositories", permissions (all READ-ONLY): Actions, Administration, Contents, Metadata, Pull requests → Generate → copy. Then github.com/khglynn/repo-standards/settings/secrets/actions → New repository secret → name `AUDIT_READ_TOKEN`, paste, Add. Then github.com/khglynn/repo-standards/actions/workflows/weekly-audit.yml → Run workflow. When it is green, the `audit-output` branch has `latest-digest.md` and next Monday's Slack message is the full one.
2. The free private build minutes run out around 16 Sep (about 2,453 of 3,000 used). The $48 budget you set on 2026-09-11 means builds keep running, billed at about $0.008 a minute after that. If you would rather not spend, the 27 jobs with no time limit are the lever (the digest will keep naming them).
3. Channel tidy, three minutes of clicks in Slack, all reversible: rename #misc-build-errors → #infra-ops; rename #eachie-system → #eachie-digest; rename the code channel "New code channel with Claude" → #claude; archive #eachie-users (2 messages ever); archive #eachie-errors-archived (dead since 2025-12-25). Leave #eachie-money for now.
4. Decide whether ynai auto-merges security bumps on a green Vercel build (default: digest-only). ynai has 4 Dependabot PRs waiting.
5. eachie #161 has a verdict in #dependabot ("Merge after a fix"): reply there with `@Claude fix and merge eachie #161` if you want it done. eachie #160 (ai 4 → 7) has no verdict yet; say the word and I relabel it to get one.
