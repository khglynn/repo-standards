# Routine: Dependabot verdict → #dependabot

**Where it runs:** claude.ai/code/routines, on Kevin's personal login (kevn.hg@gmail.com). Created 2026-09-11 as routine `trig_019EgJ3ZffYbVgTGLYkzDcj3` (https://claude.ai/code/routines/trig_019EgJ3ZffYbVgTGLYkzDcj3), model Opus 5, Slack as the only connector, first repo eachie. It was created through the playwright-2 browser profile (`~/.playwright-2`), which is signed into that login; use the same profile to edit it without touching any Claude Code profile's login.
**Trigger:** GitHub → Pull request → `labeled`. Filters: Author equals `dependabot[bot]`; Labels is one of `major-review-needed`, `dependabot-needs-human`, `no-ci-gate`, `dependabot-ci-failed`.

**Change to make by hand (added to the shared workflow 2026-09-22):** in each `Dependabot verdict · <repo>` routine, add `dependabot-ci-failed` to the trigger's "Labels is one of" filter. Nothing else changes: the prompt below already reads the tests and handles "Merge after a fix". The shared workflow applies that label when a patch or minor update it queued to merge then fails a required check; until the filter includes it, those updates reach Slack only through the Monday digest's open loops. (Labels the workflow applies do fire these routines, even though they come from `GITHUB_TOKEN`: the workflow-labelled majors on 2026-09-16 got their verdicts the same day. The "token pushes start no workflow" rule is about Actions runs, not about the Claude GitHub App's webhooks.)
**Why the label, not "opened":** the shared workflow classifies every Dependabot PR within seconds of it opening. Patch and minor bumps merge themselves once CI is green and never need a human. Firing on the label means the routine only ever runs on the exceptions, so it never spends a run (Max: 15 a day) on something that was about to merge itself, and never posts a verdict on a PR that then auto-merges.
**Connectors:** Slack only. Everything else removed from the routine.
**Repos:** one routine per enrolled repo. A routine takes exactly one GitHub trigger and a trigger names exactly one repository (checked in the form 2026-09-13), so each enrolled repo gets its own copy of this routine with only that repo attached; that also keeps each run cloning one repo. Names: `Dependabot verdict · <repo>`.

| Repo | Routine id | Created |
|---|---|---|
| eachie | `trig_019EgJ3ZffYbVgTGLYkzDcj3` (named "Dependabot verdict") | 2026-09-11 |
| festival-navigator | `trig_01Q8SKMN4TZGLLoKXViLQBwK` | 2026-09-13 |
| kevinhg-com | `trig_01YX6RSVZ63xfPyMiqy4J2Ur` | 2026-09-13 |
| list-maker | `trig_01KJQ1Lz1eaPsaVL4WsAfng5` | 2026-09-13 |
| ynai | `trig_01S8V7kddMxPZbyLrDWgEBk3` (security-only enrolment; majors among its security fixes still get a verdict) | 2026-09-14 |

All five carry the same prompt (below), Opus 5, Slack as the only connector, trigger `pull_request.labeled` filtered to author `dependabot[bot]` and labels `major-review-needed, dependabot-needs-human, no-ci-gate` — plus `dependabot-ci-failed` once the 2026-09-22 change above is made. Edit them through the playwright-2 profile; there is no duplicate button, so a sixth repo means the form again (about a dozen clicks; the recipe is in this session's BUILD-LOG entry for 2026-09-13).
**Model:** Opus 5.

**Prompt rewritten 2026-09-13 21:58 CT** after Kevin read the first automatic verdict (eachie #143) and said it was too long and too jargony. The new shape leads with verdict and risk, allows one plain sentence of why, bans acronyms and file/job names, and caps the whole message at 100 words. Refined the same night: "Why" split into "What changed" and "Why that's safe", one sentence each, because the first cut answered only the second.

**First automatic run (2026-09-13 21:38 CT):** relabelling eachie #143 fired the routine by itself within a minute of the GitHub App being linked to the personal login (see BUILD-LOG, 2026-09-13); the verdict on pnpm/action-setup 4 → 5 landed in #dependabot at 21:39:55 CT in the agreed shape.

**First verdict in the final seven-line shape (2026-09-14 02:33 CT):** eachie #161 (stripe 20.0.0 → 22.4.0, tests failing) relabelled from Kevin's login at 02:32:59; the routine fired by itself and posted at 02:33:57 — "Verdict: Merge after a fix. Risk: medium." with one sentence each for what changed and why it can hurt, "Tests: failed: …", and the exact reply to send. 74 words, no jargon, no angle brackets.

**First run (manual, 2026-09-11 22:00Z):** posted https://trimmedia.slack.com/archives/C0C1114321Z/p1789164059996589 on eachie #162 (vite 7 → 8): identified the PR by itself, found vite is dev-only (vitest + Storybook), read the v8 migration notes, ran the Storybook build under vite 8 because CI never does, recommended Merge. Prompt fixed the same evening so the last line is a plain URL (angle-bracket placeholders had become Slack link markup).

## Prompt (paste verbatim)

A Dependabot pull request in this repository was just labelled for human review. Kevin, who owns this repo, is a product person, not a developer. He asked for messages he can understand without knowing what CI, a runner, a lockfile or a build tool is. Your job is to do the reading and hand him a decision he can make in ten seconds, the way a trusted colleague would in a working session.

Do this, in order:
1. Identify the PR from the trigger payload (repository, number, title, label). Read the PR diff and Dependabot's description.
2. Find out what this package actually does for THIS app (grep for its imports and where it is used). Decide whether it touches what users see, what runs on the server, or only the tooling that builds and tests the app.
3. Read the release notes for the versions being crossed and pull out only what could affect this app.
4. Check the PR's tests: passed, failed (and in one plain sentence why), or none ran.
5. Decide: Merge, Merge after a fix, Hold, or Drop.
6. Post ONE message to the Slack channel #dependabot (channel id C0C1114321Z), in exactly this shape and nothing more:

   Line 1: "<repo> #<number>: <package> <old> → <new>"
   Line 2: "Verdict: <Merge | Merge after a fix | Hold | Drop>. Risk: <low | medium | high>."
   Line 3: "What changed: <ONE sentence, under 20 words, in everyday words: what the new version does differently. Name the one change that matters; skip the rest.>"
   Line 4: "Why that's safe: <ONE sentence, under 20 words: what this package does for the app and why the change can't hurt it (or why it can, for Hold/Drop).>"
   Line 5: "Tests: <passed | failed: one plain phrase | none ran>."
   Line 6: "To act: reply here with @Claude merge <repo> #<number>" (or, for Hold/Drop/fix, the one reply that does the right thing, in the same form).
   Line 7: the PR URL, plain, on its own line.

   Writing rules for the message: plain English only; no acronyms (write "the automatic tests", not "CI"; "the tool that installs packages", not "package manager"); no file paths, job names, branch names, version constraints or runner details; no hedging clauses; no line longer than one sentence. If a term has no everyday equivalent, leave it out rather than explain it. Keep the whole message under 100 words. Never wrap anything in angle brackets.

7. Do not merge, close, comment on, or push to the PR. Do not post anything else to Slack. If you cannot read the PR or the release notes, still post the message with "could not read" in the Why line rather than guessing.

Example of the target register (do not copy the facts, copy the tone):

   eachie #143: pnpm/action-setup 4 → 5
   Verdict: Merge. Risk: low.
   What changed: The tool now runs on a newer version of Node, the engine GitHub's test machines already have.
   Why that's safe: It only installs packages on those test machines; nothing in the app itself uses it.
   Tests: passed.
   To act: reply here with @Claude merge eachie #143
   https://github.com/khglynn/eachie/pull/143
