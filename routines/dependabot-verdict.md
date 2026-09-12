# Routine: Dependabot verdict → #dependabot

**Where it runs:** claude.ai/code/routines, on Kevin's personal login (kevn.hg@gmail.com). Created 2026-09-11 as routine `trig_019EgJ3ZffYbVgTGLYkzDcj3` (https://claude.ai/code/routines/trig_019EgJ3ZffYbVgTGLYkzDcj3), model Opus 5, Slack as the only connector, first repo eachie. It was created through the playwright-2 browser profile (`~/.playwright-2`), which is signed into that login; use the same profile to edit it without touching any Claude Code profile's login.
**Trigger:** GitHub → Pull request → `labeled`. Filters: Author equals `dependabot[bot]`; Labels is one of `major-review-needed`, `dependabot-needs-human`, `no-ci-gate`.
**Why the label, not "opened":** the shared workflow classifies every Dependabot PR within seconds of it opening. Patch and minor bumps merge themselves once CI is green and never need a human. Firing on the label means the routine only ever runs on the exceptions, so it never spends a run (Max: 15 a day) on something that was about to merge itself, and never posts a verdict on a PR that then auto-merges.
**Connectors:** Slack only. Everything else removed from the routine.
**Repos:** every enrolled repo (eachie first; add each repo as it is enrolled).
**Model:** Opus 5.

**First run (manual, 2026-09-11 22:00Z):** posted https://trimmedia.slack.com/archives/C0C1114321Z/p1789164059996589 on eachie #162 (vite 7 → 8): identified the PR by itself, found vite is dev-only (vitest + Storybook), read the v8 migration notes, ran the Storybook build under vite 8 because CI never does, recommended Merge. Prompt fixed the same evening so the last line is a plain URL (angle-bracket placeholders had become Slack link markup).

## Prompt (paste verbatim)

A Dependabot pull request in this repository was just labelled for human review. Your job is to give Kevin, a technical non-developer, enough context and a recommendation to decide in Slack, the way a good colleague would in a working session. Never post "this exists, do it?".

Do this, in order:
1. Identify the PR from the trigger payload (repository, number, title, label). Read the PR diff and Dependabot's description.
2. For each dependency in the PR: say in one plain sentence what this library does in THIS app (grep the code for its imports and the call sites; name the files). If it is unused, say so.
3. Read the library's release notes or changelog for the versions being crossed (Dependabot links them; otherwise fetch from the package's repository). Pull out only what could affect this app: breaking changes, removed APIs, changed defaults, new minimum Node or Python versions, and any security fix.
4. Check CI on the PR: which checks passed, failed, or never ran. If a check failed, read the log and say in one line why.
5. Decide: Merge / Merge after a small fix / Hold / Drop. Give the risk in one line and the reason.
6. Post ONE message to the Slack channel #dependabot (channel id C0C1114321Z) in this exact shape, in plain English, no jargon without a gloss, no headings:

   REPO #NUMBER: PACKAGE OLD → NEW (LABEL)
   What it does here: one or two sentences, name the files
   What changed: two to four short lines, only what matters to this app
   Tests: passed / failed because … / no CI in this repo
   Recommendation: Merge, Merge after a fix, Hold, or Drop — one-line reason
   Do it: the single next action, always as a reply IN THIS THREAD that names the PR, for example "Reply here: @Claude merge eachie #162", or "Reply here: @Claude fix what breaks in eachie #162 and open a PR", or "Reply here: @Claude close eachie #162, we don't use it". Naming the repo and number matters: a reply without them makes the Slack app guess from older messages.
   The PR's URL, plain, on its own last line. Write URLs as plain text only; never wrap anything in angle brackets, because Slack turns <…> into link markup.

7. Do not merge, close, comment on, or push to the PR. Do not post anything else to Slack. If you cannot read the PR or the changelog, post the message anyway with "could not read (the thing)" in the relevant line rather than guessing.

Keep the whole message under 180 words.
