# repo-standards

**One place that decides how dependency updates work across all of Kevin's repos.**

Last verified: 2026-09-11.

---

## The mental model (read this part)

Keeping dependencies current is really **two separate jobs**, and almost all the confusion
about Dependabot comes from treating them as one.

**Job one — don't ship a known vulnerability.**
When somebody publishes a CVE against a package you use, GitHub notices and opens a pull
request to fix it. This is switched on **account-wide** for every repo you own, including
new ones, and it needs **no file in any repo**. It was turned on 2026-09-11 and it is
already working everywhere. Nothing in this repository is required for it.

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

Two deliberate details behind that table:

**Nothing auto-merges in a repo without a required status check.** This is not caution for
its own sake. `gh pr merge --auto` on a branch with no required check does not queue
anything — it merges *on the spot*
([cli/cli#13880](https://github.com/cli/cli/issues/13880), still open). So "auto-merge" in
a repo with no CI means "merge instantly, untested". The workflow refuses and labels
instead.

**A grouped PR has to be clean all the way through.** Dependabot's own metadata action
publishes a convenient single "update type" for a PR — but that value is the *maximum*
level across all the packages in it **and it ignores the ones it could not read**. A
grouped PR holding one patch bump plus one unrecognised change reports itself as
`semver-patch`. So this workflow ignores that number and checks every package in the PR
individually. Every one has to be an allowed level, or the whole PR stops.

---

## How to enroll a repo

```bash
cd ~/DevKev/personal/repo-standards

# See what it would do, change nothing:
bin/enroll khglynn/some-repo --ci-check <the CI job name> --dry-run

# Actually do it:
bin/enroll khglynn/some-repo --ci-check <the CI job name>
```

It creates the labels, works out which package ecosystems the repo has, writes the files,
**opens a pull request** (it never pushes to `main`), turns on the repo's "allow auto-merge"
setting, and adds a rule requiring that CI check on the default branch — with **you** able
to bypass it, so pushing straight to `main` still works exactly as it does today.

Then **you merge the pull request.** Nothing takes effect before that: GitHub will only run
a workflow that is already on the default branch.

**The `--ci-check` value** is the *job* name from the repo's CI workflow, not the workflow's
name. For example in `festival-navigator/.github/workflows/ci.yml`, the workflow is called
`CI` but the job is `checks` — `checks` is the right answer. Leave the flag off and the repo
gets labels and update PRs, but nothing will merge on its own.

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

---

## How to see where everything stands

```bash
bin/audit
```

Read-only, writes nothing. About two and a half minutes across 40 repos (measured
2026-09-14) — most of that is measuring Actions minutes, which costs roughly 1,600 API
calls, a third of GitHub's hourly allowance. `bin/audit --skip-actions` does the
enrolment half in about 40 seconds and spends almost nothing — and every output then
says the build-time and permission checks were **not measured**, rather than reporting
them as zero and clean. (It printed "about 0 minutes of the free 3,000 … inside the free
pool" for exactly one morning, 2026-09-14.) If the hourly budget is
already gone the audit says so and refuses to start, rather than printing a full table
in which every repo reads "could not be read". It prints a markdown table
with one row per repo and one **status** word at the end:

- `enrolled` — updates land by themselves here
- `security-only` — protected against known vulnerabilities, not kept current. A fine
  resting state for a repo nobody deploys
- `fork — upstream's config, leave it alone` — a fork's `dependabot.yml` belongs to whoever
  you forked from. Enrolling one means a merge conflict on every sync, so forks are never
  counted as drift. `enroll` refuses them outright (`ALLOW_FORK=1` overrides, if you ever
  genuinely own a fork's config)
- `drift: <reason>` — half-enrolled, and the reason says which half

That status column is the drift check. Run it monthly, or when something feels stale.

### What the weekly digest tells you

```bash
bin/audit --digest
```

The same facts as the table, written for a person rather than a spreadsheet. This is what
lands in `#dependabot` every Monday morning (the routine that posts it is described in
[`routines/weekly-digest.md`](routines/weekly-digest.md)). It answers three questions and
nothing else:

**Is anything waiting for you?** How many repos keep themselves up to date, how many update
pull requests are sitting open, and how old the oldest one is — then one line per repo that
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
skipped or could not finish reads "Build time was not checked this week, so there is no
figure and no run-out date — not a zero", and adds that a repo could be half set up in a
way the message cannot see. That sentence is the whole point of the digest: a number you
can act on, or an admission — never a confident zero standing in for a measurement nobody
took.

It closes with one line beginning "To act:" — the single most useful thing to do that week.

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
| `mins (est)` | GitHub Actions minutes this billing month, **an estimate** — rebuilt from each job's start and finish, rounded up to the minute the way GitHub bills. Public repos are free and marked so. `⚠ capped` means the repo had more runs than were measured, so its number is low |

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
| `bin/lib/` | The ecosystem detector, the PR-job lister `enroll` validates `--ci-check` against, the fetch-metadata trailer parser, the Actions scanner and workflow-hygiene parser behind the audit's newer columns, and the four self-checks CI runs |
| `bin/lib/fixtures/` | Worked examples the self-checks assert against — each file says at the top what it is supposed to prove |
| `routines/` | The prompts for the scheduled Claude routines that post to `#dependabot`: a per-pull-request verdict, and the weekly digest |
| `BUILD-LOG.md` | What was built and what was found, as it happened |

**There are no secrets in this repo and there never will be.** It is public on purpose: a
*private* reusable workflow can only be called by the owner's private repos, while a public
one can be called by all of them.
