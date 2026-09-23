# repo-standards

**One place that decides how dependency updates work across all of Kevin's repos.**

Last verified: 2026-09-22 (open loops added that day, and a failed-test watch that ships switched off).

---

## The mental model (read this part)

Keeping dependencies current is really **two separate jobs**, and almost all the confusion
about Dependabot comes from treating them as one.

**Job one — don't ship a known vulnerability.**
When somebody publishes a CVE against a package you use, GitHub notices and opens a pull
request to fix it. This is switched on **account-wide** for every repo you own, including
new ones, and it needs **no file in any repo**. It was turned on 2026-09-11. Nothing in
this repository is required for it.

> **Caveat, found 2026-09-22:** "working everywhere" is true for alerts raised *after* the
> setting went on, not for the ones that already existed. When it was switched on
> account-wide, some repos' existing alerts were all backfilled in the same minute, and
> Dependabot never attempted a fix for them: a security fix only fires on a new alert or on
> an enable event. Those repos showed security updates on, open fixable alerts, and zero
> Dependabot runs ever. The fix is to switch the repo's Dependabot security updates **off and
> back on** (Settings → Advanced Security, or `gh api -X DELETE
> repos/<owner>/<repo>/automated-security-fixes` then `gh api -X PUT` on the same path), which
> is that enable event — Dependabot started within seconds in every repo it was tried on.
> The audit's open loops list any repo still in this state and name the same fix.

**Job two — don't fall three years behind.**
Routine "there's a newer version" updates. This one *does* need a file per repo
(`.github/dependabot.yml`), and that is what this repository stamps out. A repo without
one is not broken — it is just frozen in time, with job one still protecting it.

**And then: what happens to all those pull requests?**
That is the third piece, and it is the one that used to live copy-pasted in each repo and
drift. Now there is **one** copy of the merge rules, here, in
[`.github/workflows/dependabot-automerge.yml`](.github/workflows/dependabot-automerge.yml).
Each repo keeps a ten-line file that points at it. Fix a rule here, every repo gets the fix.

```
  account setting  ──────────────►  security fixes everywhere, no file needed
  .github/dependabot.yml  ───────►  "open PRs for new versions" (one file per repo)
  the ten-line stub  ────────────►  points at THIS repo's merge rules
```

---

## What actually merges by itself

| What Dependabot proposes | What happens |
|---|---|
| Patch bump (`1.2.3 → 1.2.4`) | Approved, merges as soon as CI is green |
| Minor bump (`1.2.3 → 1.3.0`) | Approved, merges as soon as CI is green |
| Major bump (`1.2.3 → 2.0.0`) | Labelled `major-review-needed`, waits for you |
| A mix it can't classify | Labelled `dependabot-needs-human`, waits for you |
| Anything, in a repo with no CI | Labelled `no-ci-gate`, waits for you, with a comment saying why |
| A patch or minor whose tests then **fail** | Stays queued. Listed in the Monday digest's open loops; labelled `dependabot-ci-failed` at once only in a repo that has turned the watch on (off by default, since 2026-09-22) |

Two deliberate details behind that table:

**Nothing auto-merges in a repo without a required status check.** This is not caution for
its own sake. `gh pr merge --auto` on a branch with no required check does not queue
anything — it merges *on the spot*
([cli/cli#13880](https://github.com/cli/cli/issues/13880), still open). So "auto-merge" in
a repo with no CI means "merge instantly, untested". The workflow refuses and labels
instead.

**A queued update whose tests go red is said out loud.** The workflow runs when the pull
request opens, seconds before its tests finish, so until 2026-09-22 a patch or minor update
that then went red simply sat there: auto-merge queued, GitHub waiting forever, no label, no
message. One grouped update did that for six days. Now the Monday digest lists every such
update under its open loops. For a same-day message there is also a **failed-test watch,
OFF by default**: the workflow waits for the required checks and labels a failure
`dependabot-ci-failed`, which a verdict routine then posts about. It ships off because the
wait costs private runner time — about two extra minutes per update pull request at the
check times measured that day, in a month the account was already past its allowance — and
because the digest already catches these weekly. With it off, the shared workflow does
exactly what it did before 2026-09-22.

To turn it on in one repo, all three:
1. in that repo's `.github/workflows/dependabot-automerge.yml`, uncomment `checks: read`
   and `statuses: read` under `permissions:` (on a private repo the watch cannot see a
   result without them);
2. in the same file's `with:` block, set `watch-minutes: 10` (15 at most);
3. add `dependabot-ci-failed` to that repo's verdict routine's "Labels is one of" filter
   (see `routines/dependabot-verdict.md`).

A later push that is not seen failing takes the label off. (A failed job re-run to green
without a push starts no run, so there the label stays until removed by hand.) The audit
table names any stub that turns the watch on without the two read lines.

**A grouped PR has to be clean all the way through.** Dependabot's own metadata action
publishes a convenient single "update type" for a PR — but that value is the *maximum*
level across all the packages in it **and it ignores the ones it could not read**. A
grouped PR holding one patch bump plus one unrecognised change reports itself as
`semver-patch`. So this workflow ignores that number and checks every package in the PR
individually. Every one has to be an allowed level, or the whole PR stops.

---

## How to enroll a repo

There are **three shapes**, and you pick between them by answering one question about the
repo: *what, if anything, actually builds or tests a change before it merges?*

### 1. The full shape — the repo has its own CI

```bash
cd ~/DevKev/personal/repo-standards

# See what it would do, change nothing:
bin/enroll khglynn/some-repo --ci-check <the CI job name> --dry-run

# Actually do it:
bin/enroll khglynn/some-repo --ci-check <the CI job name>
```

Routine "there's a newer version" pull requests start arriving, and the patch and minor
ones merge themselves as soon as that job goes green. `enroll` works out which package
ecosystems the repo has and writes a `dependabot.yml` covering them — unless the repo
already has one, which it never overwrites.

**The `--ci-check` value** is the *job* name from the repo's CI workflow, not the workflow's
name. For example in `festival-navigator/.github/workflows/ci.yml`, the workflow is called
`CI` but the job is `checks` — `checks` is the right answer.

### 2. Security fixes only, gated on something that is not a workflow

About 29 repos have no CI workflow at all — but several of them *deploy*, so something does
build every change: Vercel, or Cloudflare. That build is a perfectly good gate. It simply
is not a GitHub Actions job, and until 2026-09-14 this tool had no way to say so.

```bash
bin/enroll khglynn/ynai --security-only --external-check Vercel --dry-run
```

**`--security-only`** writes no `dependabot.yml`, so no routine version bumps are opened in
this repo at all. GitHub's account-wide *security* fixes still arrive — those need no file
in any repo — and from here on they approve and merge themselves once the check is green.
If the repo already has a `dependabot.yml` it refuses, because version updates would keep
arriving and the promise would be false.

**`--external-check <context>`** takes a required check that no workflow declares. Nothing
in the repo can confirm that name, so `enroll` confirms it against history instead: it reads
the five most recent pull requests and, for each one, what actually reported a check on it.
A name nothing has ever reported is refused, with the real names printed. One mistyped
letter is all it takes to build a gate that can never go green, and every update pull
request would then queue behind it forever.

It also looks at **whose** pull requests those were, because a check that reports on your
pull requests may not report on Dependabot's — a Vercel project can be set to skip bot
branches, and a workflow can be scoped to branches Dependabot never uses. So:

- reported on a Dependabot pull request → that is the real proof, and it says which one;
- reported only on yours, with no Dependabot pull request among the five → accepted, with a
  line telling you nothing here proves it fires on a `dependabot/*` branch. Watch the first
  security PR;
- reported on yours while Dependabot's newest readable pull request went without it →
  **refused.** That is not a missing answer, it is the wrong one, seen directly — and an
  older Dependabot pull request that *did* have it does not overrule the newest one, because
  an integration that stopped building bot branches last week looks exactly like that.

That last refusal can be wrong in one case a person can see and the script cannot: a
Dependabot pull request that predates the integration, or one opened seconds ago whose build
has not started. Re-run with `ALLOW_UNPROVEN_CHECK=1` and it is accepted with the warning
kept — the same escape-hatch shape as `ALLOW_FORK=1`.

The one thing to know about this shape: **the gate belongs to somebody else.** If the Vercel
project is deleted, or stops building this repo's branches, the check goes quiet and pull
requests pile up waiting rather than failing. Worth a glance if updates stop landing.

### 3. Security fixes only, nothing merging

```bash
bin/enroll khglynn/some-repo --security-only
```

The labels and the merge rules, no `dependabot.yml`, and no gate. Security fixes arrive and
wait for you, labelled `no-ci-gate`. Use it for a repo that should be under the standard but
has nothing to test it with yet — the audit will keep saying it is half set up, which is
exactly what you want it to say until the gate exists.

If the branch turns out to *already* require a check — from a ruleset you set up months ago,
say — `enroll` reads that and tells you, rather than promising that nothing will merge.
Leaving the flag off means "I am not naming a check", not "this branch has none".

### What happens in all three

`enroll` creates the labels, **opens a pull request** (it never pushes to `main`), turns on
the repo's "allow auto-merge" setting and its "Actions may approve pull requests" switch,
and adds a rule requiring your check on the default branch — with **you** able to bypass it,
so pushing straight to `main` still works exactly as it does today.

Then **you merge the pull request.** Nothing takes effect before that: GitHub will only run
a workflow that is already on the default branch.

Running `enroll` twice does nothing the second time — including leaving any exception you
carved into the stub exactly where you put it. Re-running it across every repo is the
intended way to roll out a change.

---

## How to carve an exception

Open the repo's `.github/workflows/dependabot-automerge.yml` — the ten-line stub — and
uncomment the one line you want to differ. Every option is listed there with a comment.
For example, in a repo where a minor version once broke production:

```yaml
    with:
      merge-minor: false   # minors wait for a human here — <the reason>, <the date>
```

Write the reason on the line. An exception with no reason becomes cargo cult in six months.

**Re-running `enroll` will not undo it.** Once a repo's stub points at repo-standards,
`enroll` leaves that file completely alone and says so. (Until 2026-09-11 it re-stamped the
template every run, which silently reverted exactly this — and the PR it opened described
itself only as "a ten-line workflow", so the revert was invisible unless you read the diff.)
The trade is the other way round now: if the *stub template itself* ever changes, already-
enrolled repos do not pick it up. To force a refresh, delete that repo's stub and re-run.

**Do not** edit the merge logic in one repo. That is the drift this whole thing exists to
end; the audit will flag it as `drift: still has its own private copy of the merge rules`.

---

## What the labels mean

| Label | Meaning | What to do |
|---|---|---|
| `dependencies` | Dependabot opened it. Applied to everything. | Nothing |
| `major-review-needed` | Major version bump. Something may genuinely break. | Read the changelog, test, merge or close |
| `dependabot-needs-human` | The workflow could not classify this PR — or the workflow run itself failed, or it could not read the branch's protection settings. | Look at the PR's checks tab |
| `dependabot-opted-out` | Classified fine, but this repo has that tier switched off in its stub (`merge-minor: false`, say). Nothing is broken. | Read it and merge it yourself, or change the stub |
| `no-ci-gate` | The repo has no required status check, so auto-merge would have been instant-merge. | Merge by hand, or give the repo a CI check and re-run `enroll` |
| `dependabot-ci-failed` | A patch or minor update was queued to merge and a required check then failed. Still queued: it lands by itself if a fix goes green. | Read the verdict in `#dependabot`; fix the test, or close the pull request |

---

## How to see where everything stands

```bash
bin/audit
```

Read-only, writes nothing. About two and a half minutes across 40 repos (measured
2026-09-14) — most of that is measuring Actions minutes, which costs roughly 1,600 API
calls, a third of GitHub's hourly allowance. The open-loops scan adds about 250 calls and
half a minute (measured 2026-09-22; `--skip-loops` leaves it out, and says so in the
output). `bin/audit --skip-actions` does the
enrolment half in about 40 seconds and spends almost nothing, and `--cap 30` samples the
minutes instead of measuring every build — every output then says the build-time and
permission checks were **not measured**, rather than reporting them as zero and clean.
(It printed "about 0 minutes of the free 3,000 … inside the free pool" for exactly one
morning, 2026-09-14; three more routes to that same sentence were closed later the same
day.) If the hourly budget is too low for the run you asked for, the audit refuses to
start and names the two cheaper commands, rather than printing a full table in which
every repo reads "could not be read". It prints a markdown table with one row per repo
and one **status** word at the end:

- `enrolled` — updates land by themselves here
- `enrolled (security fixes only)` — the merge rules are in place and working, and the
  `dependabot.yml` is missing on purpose (shape 2 or 3 above). No routine version bumps
  arrive; the security ones merge themselves. Counted among the repos that keep themselves
  up to date, because the repo genuinely is handled — with the parenthetical said out loud,
  since "up to date" on its own would overstate it
- `security-only` — no merge rules either. Protected against known vulnerabilities, not
  kept current, and nothing merges by itself. A fine resting state for a repo nobody
  deploys
- `fork — upstream's config, leave it alone` — a fork's `dependabot.yml` belongs to whoever
  you forked from. Enrolling one means a merge conflict on every sync, so forks are never
  counted as drift. `enroll` refuses them outright (`ALLOW_FORK=1` overrides, if you ever
  genuinely own a fork's config)
- `drift: <reason>` — half-enrolled, and the reason says which half
- `unknown: <what>` — a call failed, so that repo's answer is missing rather than clean.
  A read that did not happen is never reported as a setting that is switched off

That status column is the drift check. Run it monthly, or when something feels stale.

### What the weekly digest tells you

```bash
bin/audit --digest
```

The same facts as the table, written for a person rather than a spreadsheet. This is what
lands in `#dependabot` every Monday morning (the routine that posts it is described in
[`routines/weekly-digest.md`](routines/weekly-digest.md)). It answers three questions and
nothing else:

**Where it runs.** The audit runs in a private companion repo,
[`khglynn/repo-standards-audit`](https://github.com/khglynn/repo-standards-audit), whose
weekly GitHub Actions job checks this repo out, runs `bin/audit --digest` on Sunday
evenings (22:00 UTC since 2026-09-22, fifteen hours ahead of the routine, because GitHub
started the old Monday-morning run six hours late on 2026-09-21), and commits the result
there as `latest-digest.md`; the routine checks that
repo out, reads the file, and posts it. Two reasons it is not here: the routine cannot run
the audit itself (its cloud sandbox has no `gh` and no token that reaches the other
repos, found 2026-09-14), and the audit's output names private repos, which must not
land in a public repo's Actions log or on a public branch (Codex review, same day). The
job needs one repository secret there, `AUDIT_READ_TOKEN`: a fine-grained personal
access token that can only read (Actions, Administration, Contents, Metadata, Pull
requests — all of Kevin's repos), so a leak could look but never change anything. Until
the secret exists the job fails at its first step and the routine posts a shorter
fallback that says the automatic check could not run.

**Is anything waiting for you?** How many repos keep themselves up to date — and, when any
of them are the security-fixes-only shape, how many of that number are — plus how many
update pull requests are sitting open and how old the oldest one is — then one line per repo that
has something waiting.

**Has anything quietly fallen out of the standard?** Any repo that is half set up gets its
own line saying which half is missing. A week where nothing drifted has no such lines at
all, which is the point.

**Is the free build-time allowance about to run out?** Every private repo shares a pool of
3,000 GitHub Actions minutes a month. The digest says roughly how many are gone and, at the
current rate, the date they run out — so the answer arrives a week early rather than as
builds failing on the 27th. The number is an estimate and says so; see the audit's own
footnote for how close it is and why.

**And when it doesn't know, it says so.** A week where the build-time measurement was
skipped, could not finish, could see no private repo, or read none of their builds, says
so in place of the figure — "Build time was not checked this week, so there is no figure
and no run-out date — not a zero" — and adds that a repo could be half set up in a way the
message cannot see. A build file nobody could read gets its own note for the same reason.
That is the whole point of the digest: a number you can act on, or an admission — never a
confident zero standing in for a measurement nobody took.

**What has been left hanging?** (the open loops, since 2026-09-22) Agents open pull
requests and nobody notices when they stall, so the digest now lists the loose ends, one
numbered line per reason, oldest first:

- any pull request open more than a week, whoever opened it, grouped by the one reason it is
  not merging — ready and waiting, failing tests, a merge conflict, a draft, a review the
  rules still require;
- a Dependabot update queued to merge whose required check failed, at any age — GitHub holds
  those forever and tells nobody (the label above catches new ones; this catches the rest);
- a branch whose rules still require an approving review — retired 2026-09-15, because in a
  one-person account the only way past one is an admin bypass — with how many pull requests
  it is holding up;
- repos where Dependabot security fixes are switched on, fixable alerts are open, and
  Dependabot has not run in 14 days and has no update pull request open: the fixes are not
  running (see the caveat at the top — alerts that predate the setting were never
  attempted), and the line says to switch security updates off and back on there.

A loop the audit could not read is a note ("tests on 2 pull requests could not be read"),
never a missing line, and a week the loops were not checked at all says so. The full list,
with links, is in the table (`bin/audit`); `bin/lib/loops-scan.py` explains each rule.

**What the weekly run's token cannot see.** The audit's read-only token is a fine-grained
one, and GitHub does not let a fine-grained token read check runs at all (a known gap it
lists on *Managing your personal access tokens*, read 2026-09-22). So the weekly run reads
test results from the Actions jobs instead — same names, same answers for any check that is
an Actions job — and reports a check it cannot see, like a Vercel status, as not read. It
also cannot read security alerts until the token is given **Dependabot alerts: read** (and
Vercel-style statuses need **Commit statuses: read**); until then the digest carries a
note saying the security-fix check did not run.

It closes with one line beginning "To act:" — the single most useful thing to do that week.
When an open loop is the answer, the most urgent one wins, not the oldest: security fixes
that never run on critical alerts, then an update queued behind failing tests.

**It is always under 150 words**, because a message you skim is a message you read. When
there is more to say than that, the repo list gives way first and then the open loops, and
each says how many it left out; the notes never do, since a note that vanishes reads
exactly like a week in which there was nothing to report. On the busy real week of
2026-09-22 that left room for ONE numbered loop line plus "And 18 more open loops." (the
"To act:" line still named the most urgent one); `bin/audit --digest --word-cap 220` fitted
five. Raising it is the one-flag change to make in the weekly job if a longer Monday
message is fine. When not even one line fits, the block becomes a single sentence with
the count and the oldest age, never a heading over nothing.

Two things it deliberately does **not** do: it never merges, closes or comments on
anything, and on a quiet week it is three lines rather than a report about nothing.

### The columns, one line each

| Column | What it means |
|---|---|
| `manifest` | This repo has something Dependabot could keep current — an app dependency file, or just GitHub Actions workflows (an action is a dependency too, and nobody updates those by hand) |
| `dependabot.yml` | The per-repo file that asks for "there's a newer version" pull requests |
| `stub` | `yes` = points at the shared merge rules here. `source` = this repo IS the rules. `inline` = a stale private copy, which is the drift this system exists to end |
| `auto-merge` | The repo setting that lets a pull request merge itself once its checks pass |
| `approve` | The repo setting "Allow GitHub Actions to create and approve pull requests". **With it off, the shared workflow's approval is refused** and every update pull request queues behind a review that can never arrive. It cost three list-maker pull requests on 2026-09-14; an enrolled repo without it is now drift, not a warning |
| `required checks` | The check that has to be green before anything merges. No check means nothing auto-merges at all, on purpose |
| `open bot PRs` | Dependabot pull requests sitting open right now, and the age of the oldest |
| `mins (est)` | GitHub Actions minutes this billing month, **an estimate** — rebuilt from each job's start and finish, rounded up to the minute the way GitHub bills. Public repos are free and marked so. Dependabot's own update runs are left out, because GitHub does not bill those on standard runners; counting them had `ynai` reading 15 minutes for a month that cost nothing. `⚠ capped` means the repo had more builds than were measured, so its number is low. Self-hosted runners count as free, because GitHub bills none of their minutes |

And under the table, two **warnings** — which are not drift, and nothing about them is
broken:

- **A job with no time limit.** If it hangs it inherits GitHub's six-hour default, so one
  stuck job can eat an eighth of the month's allowance while looking exactly like a job
  that is still working. One line of YAML fixes it.
- **A workflow that runs on both a branch push and the pull request.** Every commit on a
  pull-request branch then runs it twice, for twice the minutes. Reported rather than
  flagged, because some repos want a branch gate before a pull request exists.

To ask about one specific pull request instead of the whole account:

```bash
bin/classify-pr khglynn/eachie 162
```

It prints the packages in that PR and what the workflow would decide — merge, or which
label — without running anything or merging anything.

---

## Decisions, and what is still unverified

**2026-09-11 — gate on the per-dependency list, never the aggregate.**
`dependabot/fetch-metadata`'s `update-type` output is the maximum level across the PR *and
it skips nulls*, so a grouped patch-plus-unknown PR reports `semver-patch`. We read
`updated-dependencies-json` and require every entry individually. Verified against two real
eachie PRs — see [BUILD-LOG.md](BUILD-LOG.md).

**2026-09-11 — the action is pinned to a commit SHA, not a tag.**
`dependabot/fetch-metadata@25dd0e34…` is v3.1.0. A tag can be moved to new code by whoever
controls the repository, and this workflow runs with write permission in yours.

**2026-09-11 — rulesets let repository admins bypass, always.**
A `required_status_checks` rule blocks direct pushes to the branch as well as merges. Kevin
pushes straight to `main` in several repos, so every ruleset `enroll` creates lists
repository admins as a bypass actor (`actor_id: 5`, `bypass_mode: always`). The bot is
`github-actions`, not an admin, so the check still genuinely gates the automated path.
**Confirmed working the same day:** a push to this repo's `main` while its `checks` ruleset
was active went through and printed `remote: Bypassed rule violations for refs/heads/main`.

**2026-09-11 — forks are out of scope, and `enroll` refuses them.**
Six of the 39 repos are forks (`google_workspace_mcp`, `okta-mcp-server`,
`trimmedia.github.io`, `awesome-mcp-servers`, `starter`, `patchwork`). Their dependency
config is upstream's; overwriting it buys a merge conflict on every sync. The audit gives
them their own status word so they never show up as drift to chase.

**2026-09-11 — this workflow never pushes to a pull-request branch. `update-branch` was
removed the same day it was written.**
The original design said: when a Dependabot PR has fallen behind `main` *and* a required
check is red, merge `main` into the PR branch (`gh pr update-branch`) and let the resulting
push re-run CI. That cannot work, and a review caught it before it ever ran. GitHub's rule
for the automatic token is explicit — *"events triggered by the `GITHUB_TOKEN`, with the
exception of `workflow_dispatch` and `repository_dispatch`, will not create a new workflow
run"* — and `update-branch` pushes as `github-actions[bot]`. So the push would have fired
**no** run at all: the required check would sit at "expected, waiting" forever, and on a
repo whose ruleset dismisses stale reviews on push (eachie's does) the bot's approval would
have been thrown away too. The PR would be left unmergeable *and* impossible to re-trigger.

It was also solving a problem that does not exist: every ruleset this system creates sets
`strict_required_status_checks_policy: false`, so a PR being behind its base branch does
not block the merge at all.

What the workflow does now: **approve and enable auto-merge first**, always, once the CI
gate is clear. A red check simply leaves the PR queued — GitHub merges nothing until it goes
green — so nothing can be stranded by what happens afterwards. Then, if the PR is both
behind base *and* red, it logs a warning saying so. `stale-strategy` is `none` by default.

**⚠ Still unverified: `stale-strategy: comment`.** Set it and the workflow posts
`@dependabot recreate` (once per head commit). Dependabot's own push *does* re-run CI,
because Dependabot is a real app and not `GITHUB_TOKEN` — so if it obeys, this works. **What
nobody has confirmed is whether Dependabot obeys a command posted by `github-actions[bot]`
rather than a person.** It is known to work from a real user's comment (2026-09-11), and
known *not* to work from a Claude Code cloud session, whose comments get mangled.

**The test, once the eachie stub is on `main`:** set one repo's stub to `stale-strategy:
comment`, wait for a stale red Dependabot PR, and see whether `dependabot[bot]` reacts within
a minute or two. Record the answer here. Also note: `@dependabot merge`, `squash`, `close`
and `reopen` were **removed on 2026-01-27** — only `rebase` and `recreate` remain.

**2026-09-11 — nothing auto-merges in *this* repo, on purpose.**
Every dependency repo-standards has is a GitHub Action, and those actions run with write
permission inside every enrolled repo including the private ones. The only check here is
`checks` — actionlint and a template parse — which can say a workflow is well-formed and
cannot say an action's new code is safe. Auto-merging a patch bump of
`dependabot/fetch-metadata` would have undone the SHA-pinning argued for above: pinning
stops a *tag* being re-pointed, but a bot that merges the SHA change itself puts you back
where you started. So `dependabot-automerge-self.yml` carries
`merge-patch: false, merge-minor: false`, and every action bump here gets a human. It is a
handful a month.

**2026-09-11 — `enroll` validates `--ci-check` before it writes anything.**
A required status check is a free-text *context* string, and GitHub accepts one that nothing
will ever report. A typo (`check` for `checks`) would create a gate that can never go green:
Kevin bypasses it as an admin and never notices, while every Dependabot PR queues auto-merge
and hangs forever — precisely the silent failure this system exists to prevent. `enroll` now
reads the target repo's own workflows and refuses a name that is not a job id running on
`pull_request`, printing the real names. It does this straight after the clone, before a
single write, so a bad name costs nothing.

**2026-09-11 — "no classic branch protection" is not the same as "I could not look".**
Reading `/branches/{branch}/protection` requires **admin** rights and `GITHUB_TOKEN` is not
an admin, so on a classically-protected repo that call returns **403, not 404**. The
workflow used to swallow both and print "no classic branch protection on main" — a false
statement about the repo, followed by a `no-ci-gate` label and advice ("add a CI workflow")
that is wrong for a repo which already has one. It now separates the two: 404 means absent,
403 means *unknown*, which gets `dependabot-needs-human` and a warning naming the cause.
The durable fix is rulesets everywhere — `enroll` only ever creates those, and the ruleset
endpoint is readable without admin.

**2026-09-22 — the shared workflow declares no permissions; each stub grants them.**
A called workflow can only narrow what its caller granted, and asking for a scope the caller
did not grant is not a narrowing — the run fails to start ("the nested job is requesting
'checks: read', but is only allowed 'checks: none'"). The failed-test watch needs
`checks: read` and `statuses: read`, which no enrolled stub grants, so declaring them in the
shared file would have stopped every enrolled repo at once. The shared file now declares
nothing and inherits the stub's grant exactly — which, for every stub as it stands, is the
same three scopes it always ran with. `templates/caller-stub.yml` carries the two read lines
commented out, next to `watch-minutes`, for a repo that turns the watch on. Because the
shared file no longer caps anything, the template check allows exactly those three scopes,
and the audit table names a stub that grants more.

**2026-09-22 — the failed-test watch waits inside the run, because nothing later can start
one.** A `check_run` or `check_suite` event is never delivered to a workflow for a check
GitHub Actions itself created (GitHub Docs, *Events that trigger workflows*), and every
enrolled gate but one is an Actions job. `workflow_run` would need each repo's workflow
names written into its stub, and `status` would start a run for every commit status on every
branch. Waiting a bounded few minutes in the run that queued the merge costs the check's own
duration in runner time and needs only the two permission lines. Shipped OFF by default the
same day (the coordinator's call): merging it changes nothing until a repo opts in, and the
job's ceiling stays 10 minutes there.

**⚠ Still unverified (2026-09-22): the watch has never run live.** It is off by default and
only runs from `main`, so its first real test is the first patch or minor update in a repo
that turns it on. Its decision rule was run against real pull requests (a red queued update
reads `failed:<check>`, a green one `passed`, a moved head `moved`); what has not been seen
is the workflow's own token reading checks with the two read lines granted, or the label
reaching a verdict routine.

---

## What is in here

| Path | What it is |
|---|---|
| `.github/workflows/dependabot-automerge.yml` | **The merge rules.** The one copy. Every repo calls this. |
| `.github/workflows/ci.yml` | This repo's own CI — lints the shared workflow before it can ship to everywhere |
| `.github/workflows/dependabot-automerge-self.yml` | This repo's own stub. Named differently only because the obvious name is taken by the definition above |
| `templates/caller-stub.yml` | The ten-line file `enroll` copies into each repo |
| `templates/dependabot/` | Per-ecosystem fragments (npm, pip, uv, github-actions) that `enroll` splices into a `dependabot.yml` |
| `bin/enroll` | Enroll one repo. Idempotent. Opens a PR, never pushes to `main` |
| `bin/audit` | Read-only status of every repo |
| `bin/classify-pr` | Read-only. "What would the workflow do with this PR?" — answers it without waiting for a run |
| `bin/lib/` | The ecosystem detector, the PR-job lister `enroll` validates `--ci-check` against, the fetch-metadata trailer parser, the Actions scanner and workflow-hygiene parser behind the audit's newer columns, the open-loops scanner (`loops-scan.py`), and the five self-checks CI runs |
| `bin/lib/fixtures/` | Worked examples the self-checks assert against — each file says at the top what it is supposed to prove |
| `routines/` | The prompts for the scheduled Claude routines that post to `#dependabot`: a per-pull-request verdict, and the weekly digest |
| `BUILD-LOG.md` | What was built and what was found, as it happened |

**There are no secrets in this repo and there never will be.** It is public on purpose: a
*private* reusable workflow can only be called by the owner's private repos, while a public
one can be called by all of them.
