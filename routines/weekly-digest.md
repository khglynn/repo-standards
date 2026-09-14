# Routine: Dependabot weekly digest → #dependabot

**What it is for.** Once a week, one message in Slack that answers three questions without
anybody opening GitHub: is anything waiting for Kevin, has any repo quietly fallen out of
the standard, and is the free build-time allowance about to run out. It is the "automated
check so nothing drifts" from Kevin's original ask.

**Where it runs.** claude.ai/code/routines, on Kevin's personal login (kevn.hg@gmail.com),
created and edited through the `playwright-2` browser profile (`~/.playwright-2`) — the
same profile that owns the four `Dependabot verdict` routines. See
`routines/dependabot-verdict.md` for why that profile and not the Claude in Chrome
extension.

**How it differs from the verdict routines.** Those fire on a GitHub event, one routine per
repo, and speak about a single pull request. This one is on a clock, covers every repo at
once, and speaks about the account. They do not overlap: a Dependabot pull request that is
still open on Monday gets one line here and keeps whatever verdict it already got.

---

## Form values — create it by hand at claude.ai/code/routines/new

The click-by-click recipe that works in this form is in BUILD-LOG, 2026-09-13 22:44. The
one thing that recipe does not cover is the schedule card, because every routine built so
far used a GitHub trigger. **Unverified as of 2026-09-14: nobody has filled in the schedule
card in this form yet.** Expect the field names below to be close but check them on screen.

| Field | Value |
|---|---|
| Name | `Dependabot weekly digest` |
| Instructions | the prompt below, pasted verbatim |
| Model | `Opus 5` |
| Repository | `khglynn/repo-standards` |
| Trigger | **Schedule**, weekly, **Monday**, **08:00**, timezone **America/Chicago** |
| Connectors | **Slack** and the **GitHub** connector, and nothing else |
| Auto-fix | off |

**Clearing the connectors is the fiddly part** and it behaves the same way here as in the
verdict routines: click the first `Remove` button, let the list re-render, click the first
one again, and repeat until none are left — clicking all of them in one pass races the
re-render and leaves a random one behind. Then add Slack and GitHub back through
"Add connector".

**Why the repository is `repo-standards` and not one of the product repos.** The routine
needs the checkout only to run `bin/audit`, which lives here. It reads every other repo
through the GitHub API, not through a checkout.

**Verify on the routine's page after saving:** the name, `Default · Opus 5`, the schedule
line reading Monday 08:00 America/Chicago, `khglynn/repo-standards`, exactly two
connectors, and the phrase "runs out" somewhere in the instructions.

---

## Prompt (paste verbatim)

Every Monday morning you post one short status message about Kevin's repositories to
Slack. Kevin owns these repos and is a product person, not a developer: he wants to know
whether anything needs him this week, and he should not have to know what a runner, a
lockfile or a build minute is to understand the answer.

Do this, in order:

1. Try the real audit first. In the checked-out repository, run `gh auth status`. If it
   succeeds, run `bin/audit --digest` and wait for it — it takes two to three minutes
   across about forty repositories, which is normal and not a hang. Its output is already
   written in the shape described below; use its numbers exactly as printed and do not
   recompute them.

   Two things it may tell you instead of a number, and both must survive into the message
   word for word rather than being tidied away: that build time was not checked this week
   (it will say so in place of the minutes, and there is then no figure and no run-out
   date — do not write a zero, and do not work one out yourself), and that some
   repositories could not be read. An unchecked week and a clean week look identical
   unless the message says which one this was.

   If it refuses to start because GitHub's hourly limit is too low, it says when to come
   back and prints two cheaper commands. Do not wait for the reset: run
   `bin/audit --digest --skip-actions`, which costs almost nothing and still reports
   which repositories have fallen out of the standard. That output says for itself that
   build time went unchecked; carry it through. If that refuses too, go to step 2 and say
   the automatic check could not run.

2. If `gh auth status` fails, or `bin/audit --digest` exits non-zero or prints nothing,
   fall back to the GitHub connector. List the open pull requests opened by Dependabot in
   each of these repositories: eachie, festival-navigator, kevinhg-com, list-maker. Count
   them and find the oldest. You will not be able to check for drift or for build-time
   usage this way, and you must say so in plain words rather than leaving it out.

3. Post ONE message to the Slack channel #dependabot (channel id C0C1114321Z).

   **If `bin/audit --digest` ran, post what it printed, as it printed it.** It is already
   written for Kevin, already inside the length it needs to be, and already says the
   careful things — that the minutes are an estimate, that a figure is a floor, that
   something went unmeasured. Do not rewrite it, do not summarise it, do not drop lines to
   make it shorter, and do not add a line of your own. If some part of it reads oddly,
   post it anyway and say so in your run notes; the wording belongs in the tool, where it
   can be reviewed, not in a rewrite nobody sees.

   **Only if you fell back to step 2**, write the message yourself in this shape:

   A single opening line: how many repositories keep themselves up to date out of how many
   in total, how many update pull requests are waiting and how old the oldest one is, and
   roughly how many of the free three thousand build minutes this month have been used
   together with the date they are on course to run out. Say that the minutes are an
   estimate.

   Then one line per repository that has update pull requests waiting or is half set up,
   naming the repository and what is waiting or what is missing. Nothing for the repos
   that are fine.

   Say nothing about build jobs with no time limit or repeated test runs. The connector
   cannot see either, and a message that omits them without saying so reads as a week in
   which there were none.

   Then a last line beginning "To act:" giving the single most useful thing Kevin could do
   this week, written as something he can act on immediately — which repository, and what
   to do there.

   In the opening line, replace the minutes half with a plain sentence saying that the
   automatic check could not run this week, so only the waiting pull requests are
   reported. Never put a number there, and never a zero: you did not measure it.

4. Writing rules, for a message you had to write yourself. Plain English only. No acronyms
   — write "the automatic tests", not "CI". No file paths, job names, branch names or
   version numbers. One sentence per line. Keep it short enough to read at a glance, which
   is about 150 words. Never wrap anything in angle brackets: Slack turns them into link
   markup and the message breaks.

   These rules do not apply to the audit's own output, which already follows them and
   which you post unchanged. The two instructions used to contradict each other — "use its
   numbers exactly as printed" alongside a word limit the real output exceeded — which
   left the routine quietly choosing which repositories to drop. The length is the tool's
   problem now, and it enforces it.

5. Do not merge, close, approve, comment on or push to anything. Do not open issues. Do
   not post anything else to Slack. This routine only ever reads and reports.

