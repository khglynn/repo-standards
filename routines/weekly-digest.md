# Routine: Dependabot weekly digest → #dependabot

**What it is for.** Once a week, one message in Slack that answers three questions without
anybody opening GitHub: is anything waiting for Kevin, has any repo quietly fallen out of
the standard, and is the free build-time allowance about to run out. It is the "automated
check so nothing drifts" from Kevin's original ask.

**Where it runs.** claude.ai/code/routines, on Kevin's personal login (kevn.hg@gmail.com),
created and edited through the `playwright-2` browser profile (`~/.playwright-2`) — the
same profile that owns the four `Dependabot verdict` routines. See
`routines/dependabot-verdict.md` for why that profile and not the Claude in Chrome
extension. Live since 2026-09-14 as `trig_01TTfxzWdWUA3J9PGPP6w6ap`.

**Where the audit itself runs — not in the routine, and not in this repo.** The routine's
cloud sandbox has no `gh` command at all (`gh: command not found`, found on its first run,
2026-09-14 07:02 CT) and no token that reaches the other repos, so `bin/audit` can never
run there. And its output names private repos, so it cannot be produced in this public
repo's Actions log or committed to a public branch (Codex review, 2026-09-14). It runs in
the private companion repo `khglynn/repo-standards-audit`, whose weekly job checks this
repo out, runs `bin/audit --digest` on Sunday at 22:00 UTC — fifteen hours before the
routine wakes up, since 2026-09-22, after GitHub started the old Monday 12:15 UTC run six
hours late on 2026-09-21 and the routine posted its fallback — and commits
the result there as `latest-digest.md`. The routine checks out *that* repo, reads the
file, and posts it. That split is deliberate: the part that needs credentials never
touches a model, and the part that needs a model never touches credentials. The job needs
one repository secret in the private repo, `AUDIT_READ_TOKEN`, a fine-grained personal
access token that can only read (the exact permissions are in that repo's README); until
it exists the job fails at its first step and the routine posts the fallback, which says
the automatic check could not run.

**Since 2026-09-22 the file also carries the open loops** — pull requests left open more
than a week and why, updates queued behind failing tests, review rules that strand work, and
security fixes that never run. Nothing in this routine changes for that: it posts the file
as written. The fallback in step 2 cannot see any of it and should not try.

**How it differs from the verdict routines.** Those fire on a GitHub event, one routine per
repo, and speak about a single pull request. This one is on a clock, covers every repo at
once, and speaks about the account. They do not overlap: a Dependabot pull request that is
still open on Monday gets one line here and keeps whatever verdict it already got.

---

## Form values — create it by hand at claude.ai/code/routines/new

The click-by-click recipe that works in this form is in BUILD-LOG, 2026-09-13 22:44. The
schedule card, first filled in on 2026-09-14: pressing **Weekly** selects Monday by itself
and shows a plain `At` time box; the timezone is the browser's own and the card confirms
it in words ("Runs every Monday at 8:00 AM CDT"). The GitHub connector appears in the
"Add connector" list under the name **Github+**. Typing a name into that list's search box
and clicking the one match is the reliable way to add a connector.

| Field | Value |
|---|---|
| Name | `Dependabot weekly digest` |
| Instructions | the prompt below, pasted verbatim |
| Model | `Opus 5` |
| Repository | `khglynn/repo-standards-audit` (the private repo that holds `latest-digest.md`) |
| Trigger | **Schedule**, weekly, **Monday**, **08:00**, timezone **America/Chicago** |
| Connectors | **Slack** and **Github+**, and nothing else |
| Auto-fix | off |

**Clearing the connectors is the fiddly part** and it behaves the same way here as in the
verdict routines: click the first `Remove` button, let the list re-render, click the first
one again, and repeat until none are left — clicking all of them in one pass races the
re-render and leaves a random one behind. Then add Slack and GitHub back through
"Add connector".

**Why the repository is `repo-standards-audit` and not this one.** The routine needs the
checkout only to read `latest-digest.md`, which the weekly job commits there. Everything
about the other repos is already inside that file.

**Verify on the routine's page after saving:** the name, `Default · Opus 5`, the schedule
line reading Monday 08:00 America/Chicago, `khglynn/repo-standards-audit`, exactly two
connectors (Slack, Github+), and the phrase "latest-digest.md" somewhere in the instructions.
Then press "Run now" once and read the run: it should show the file being read, or say
plainly why it fell back.

---

## Prompt (paste verbatim)

Every Monday morning you post one short status message about Kevin's repositories to
Slack. Kevin owns these repos and is a product person, not a developer: he wants to know
whether anything needs him this week, and he should not have to know what a runner, a
lockfile or a build minute is to understand the answer.

Do this, in order:

1. Read this week's audit. It was produced a few hours ago by a job on GitHub's own
   machines; this environment has no GitHub command-line tool and cannot run the audit
   itself, so do not try. The file is `latest-digest.md` at the root of the checked-out
   repository (khglynn/repo-standards-audit); read it. If the checkout is missing or the
   file is not there, ask the GitHub connector for `latest-digest.md` on the main branch
   of khglynn/repo-standards-audit. The file's first line carries the date it was
   produced; if that date is more than six days old, treat the file as missing. Its text
   is already written for Kevin; use its numbers exactly as printed and do not recompute
   them.

   Two things it may say instead of a number, and both must survive into the message
   word for word rather than being tidied away: that build time was not checked this week
   (it will say so in place of the minutes, and there is then no figure and no run-out
   date — do not write a zero, and do not work one out yourself), and that some
   repositories could not be read. An unchecked week and a clean week look identical
   unless the message says which one this was.

2. If the file is missing or stale, fall back to the GitHub connector. For each of these
   repositories — eachie, festival-navigator, kevinhg-com, list-maker — list the open pull
   requests with one list call per repository (never the search endpoint, which
   rate-limits after a few calls) and keep only the ones opened by dependabot[bot]. Count
   them and find the oldest. You will not be able to check for drift or for build-time
   usage this way, and you must say so in plain words rather than leaving it out.

3. Post ONE message to the Slack channel #dependabot (channel id C0C1114321Z).

   **If you read this week's audit file, post it as it is written.** It is already
   written for Kevin, already inside the length it needs to be, and already says the
   careful things — that the minutes are an estimate, that a figure is a floor, that
   something went unmeasured. Do not rewrite it, do not summarise it, do not drop lines to
   make it shorter, and do not add a line of your own. If some part of it reads oddly,
   post it anyway and say so in your run notes; the wording belongs in the audit, where it
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

   These rules do not apply to the audit file, which already follows them and which you
   post unchanged. The two instructions used to contradict each other — "use its
   numbers exactly as printed" alongside a word limit the real output exceeded — which
   left the routine quietly choosing which repositories to drop. The length is the tool's
   problem now, and it enforces it.

5. Do not merge, close, approve, comment on or push to anything. Do not open issues. Do
   not post anything else to Slack. This routine only ever reads and reports.

