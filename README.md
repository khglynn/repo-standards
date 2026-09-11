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

Running `enroll` twice does nothing the second time. Re-running it across every repo is the
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

**Do not** edit the merge logic in one repo. That is the drift this whole thing exists to
end; the audit will flag it as `drift: still has its own private copy of the merge rules`.

---

## What the labels mean

| Label | Meaning | What to do |
|---|---|---|
| `dependencies` | Dependabot opened it. Applied to everything. | Nothing |
| `major-review-needed` | Major version bump. Something may genuinely break. | Read the changelog, test, merge or close |
| `dependabot-needs-human` | The workflow could not classify this PR — or the workflow run itself failed. | Look at the PR's checks tab |
| `no-ci-gate` | The repo has no required status check, so auto-merge would have been instant-merge. | Merge by hand, or give the repo a CI check and re-run `enroll` |

---

## How to see where everything stands

```bash
bin/audit
```

Read-only, writes nothing, takes about 90 seconds across 39 repos (measured 2026-09-11). It prints a markdown table
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

**2026-09-11 — ⚠ UNVERIFIED: whether Dependabot obeys a comment from `github-actions[bot]`.**
When a PR has fallen behind `main` *and* a required check is red, the workflow refreshes the
branch. There are two ways to do that, and only one is proven:

- `update-branch` (**the default**) merges the base branch into the PR branch through the
  GitHub API. This always works.
- `comment` posts `@dependabot rebase` and lets Dependabot rebuild the branch properly.
  Cleaner history — but **nobody has confirmed Dependabot honours that command when a bot
  posts it.** It is known to work from a real user's comment (2026-09-11), and it is known
  *not* to work from a Claude Code cloud session, whose comments get mangled. The
  `github-actions[bot]` case has never been run. Also note: `@dependabot merge`, `squash`,
  `close` and `reopen` were **removed on 2026-01-27** — only `rebase` and `recreate` remain.

**This is the first thing to verify once the eachie stub lands on `main`.** The test:
switch one repo's stub to `stale-strategy: comment`, let a stale Dependabot PR hit the path,
and see whether `dependabot[bot]` reacts to the comment within a minute or two. Record the
answer here and delete whichever option loses. Until then the default is the boring one that
definitely works.

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
| `bin/lib/` | The ecosystem detector and the template self-check, both used by CI |
| `BUILD-LOG.md` | What was built and what was found, as it happened |

**There are no secrets in this repo and there never will be.** It is public on purpose: a
*private* reusable workflow can only be called by the owner's private repos, while a public
one can be called by all of them.
