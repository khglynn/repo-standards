# NOW — dependabot-verdicts arc (arc mode)
last-updated: 2026-09-14 00:20 CT · mode: arc · read GROUNDING.md first

## State
- Four repos enrolled and proven live (eachie, festival-navigator, kevinhg-com, list-maker). Four verdict routines live on kevn.hg@gmail.com (ids in `routines/dependabot-verdict.md`). Approve-switch bug fixed in enroll + workflow (e855c41). #dependabot has one verdict (eachie #143, old shape).
- Kevin asleep from ~00:15 CT 2026-09-14; standing instruction: do what needs no one, bank as you go.

## Exact next step
B in PLAN.md: launch the audit-improvements Workflow (brief at `claude-plans/dependabot-verdicts/brief-audit-phase2.md`), then C–F.

## For Kevin in the morning (self-contained)
- Channel tidy, three minutes of clicks in Slack, all reversible: rename #misc-build-errors → #infra-ops; rename #eachie-system → #eachie-digest; rename the code channel "New code channel with Claude" → #claude; archive #eachie-users (2 messages ever); archive #eachie-errors-archived (dead since 2025-12-25). Leave #eachie-money for now (its bot lives in eachie's code; folding it is a PR).
- Decide whether ynai auto-merges security bumps on a green Vercel build (default: digest-only).
