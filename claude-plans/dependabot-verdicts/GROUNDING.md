# Dependabot verdicts arc — RESUME / post-compaction grounding

**Last verified:** 2026-09-14 00:20 CT · **Owner:** Kevin HG (personal repos, khglynn) · **Driver:** the "trimm slack claude improvements" session (hg-agents), running unattended overnight on Kevin's word: "do what you can without me… whatever's gonna help and you feel good about and you don't need me for."

## The #1 failure mode: a post-compaction or tired session does the minimum
This arc has been "one more small thing" six times and each time the small thing hid a real defect (the fail-open merge gate, the stale-branch dead end, the unlinked GitHub App, the masked approve failure). Every claim below traces to a tool result in the session's transcript or to `BUILD-LOG.md`. Re-verify before building on anything; do not trim scope because context feels full.

## What this is, in Kevin's words
"I want it on all the repos. Simple and easy. Everything kept up to date. Don't break the bank. One config that covers all repos, small exceptions carved out per repo. An automated check so nothing drifts." And for the Slack messages: not "this code thing exists, do it?" — a decision he can make in ten seconds, both *what changed* and *why that's safe*, in tight plain English, no jargon.

## How we work
- Kevin is a product person, not a developer. Messages TO him are plain English; density is fine in code, commits and this folder.
- He merges PRs into live products (eachie, list-maker, remembrall, ynai, kevinhg-com); settings that are reversible (rulesets, repo switches, routines) we set directly. Never push to `main` of a product repo. repo-standards itself commits straight to main.
- Login-bound surfaces: the CLI profile is on ai@tecovas.com; everything on Kevin's personal claude.ai (routines, the artifact page) is reached through the `playwright-2` browser profile (`~/.playwright-2`, signed into kevn.hg@gmail.com and github.com as khglynn). One Playwright MCP owner at a time; `browser_close` releases it. The Claude in Chrome extension is disconnected.
- Cloud Claude Code sessions cannot drive Dependabot (their `@mentions` get defanged with U+00B7) and cannot wait on events; anything that waits or commands Dependabot lives in the shared workflow or in a comment from Kevin's login.
- gh writes can 401 inside the Bash sandbox; re-run that one command with the sandbox disabled rather than debugging auth.
- Independent review before anything Kevin will rely on: Codex via `~/DevKev/hg-agents/commands/lib/codex-run.sh` (start → wait, exit 2 = still running) or an Opus reviewer in a Workflow. A flaky reviewer is never a reason to skip the review.

## Ground yourself — do not skim
1. This file. 2. `NOW.md` beside it (the cursor). 3. `PLAN.md` beside it (acceptance). 4. `BUILD-LOG.md` at the repo root, newest section first — it is the DEVLOG. 5. `README.md` for the mental model. 6. hg-agents `claude-plans/2026-09-10-slack-agent-landscape.md` for the decision history and Kevin's decisions verbatim.

## Failure modes already met (do not rediscover)
- `gh pr merge --auto` merges instantly when the base has no required check; the workflow refuses unless a required check exists (rulesets or classic).
- fetch-metadata's aggregate update-type ignores unparseable entries; gate on the per-dependency array.
- A `GITHUB_TOKEN` push never re-triggers workflows; the stale-branch refresh was removed.
- A routine takes one GitHub trigger and a trigger names one repository: one routine per repo.
- The GitHub App installation only feeds webhooks to the claude.ai login that authorized it in the browser; `/web-setup` clones but never triggers.
- `gh pr review --approve` from Actions needs the repo switch "Allow GitHub Actions to create and approve pull requests"; enroll sets it, the workflow fails loudly without it.
- Pane teammates freeze mid tool-call; >10 min of transcript silence is dead. Prefer Workflows (journaled) or do it yourself.
