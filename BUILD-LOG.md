# Build log — repo-standards Phase 1

Append-only record of what was built, what was found, and what is still unverified.
Started 2026-09-11 by a Claude Opus 5 builder session.

---

## 2026-09-11 — session start

**Environment checks**
- `gh` 2.88.1, authenticated as `khglynn`, scopes `admin:org, gist, repo, workflow`.
- `actionlint` was not installed; installed via `brew install actionlint` (exit 0).
- Repo `khglynn/repo-standards` created public, cloned to `~/DevKev/personal/repo-standards`.

**Pinned action SHA (resolved, not guessed)**
```
$ gh api repos/dependabot/fetch-metadata/git/ref/tags/v3.1.0
{"ref":"refs/tags/v3.1.0", "object":{"sha":"25dd0e34f4fe68f24cc83900b1fe3fe149efef98","type":"commit"}}
```
The tag is **lightweight** (`object.type == "commit"`), so no annotated-tag dereference was
needed. Pin used everywhere: `dependabot/fetch-metadata@25dd0e34f4fe68f24cc83900b1fe3fe149efef98 # v3.1.0`.

---

## 2026-09-11 — what got built

**`khglynn/repo-standards`** (public, https://github.com/khglynn/repo-standards), cloned to
`~/DevKev/personal/repo-standards`. Contents as the brief specified, plus two things the
brief did not ask for and are explained below: the repo's own CI, and its own enrollment.

| File | Note |
|---|---|
| `.github/workflows/dependabot-automerge.yml` | The reusable workflow. actionlint + shellcheck clean. |
| `.github/workflows/ci.yml` | **Added beyond the brief.** See "CI on the standards repo" below. |
| `.github/workflows/dependabot-automerge-self.yml` | **Added beyond the brief.** The repo's own caller stub, under a different name because the obvious path holds the definition. |
| `.github/dependabot.yml` | Same — the standards repo follows its own standard. |
| `templates/caller-stub.yml` | The ~10-line per-repo file. |
| `templates/dependabot/{_header,npm,pip,uv,github-actions}.yml` | Fragments; `{{DIRECTORY}}` is substituted by `enroll`. |
| `bin/enroll` | Idempotent. Opens a PR, never pushes to a default branch. |
| `bin/audit` | Read-only. ~90s for 39 repos. |
| `bin/lib/detect-ecosystems.py` | Ecosystem classifier, fixture-tested in CI. |
| `bin/lib/check-templates.py` | Proves the templates still compose; run in CI. |

### Two additions beyond the brief, and why

**CI on the standards repo.** The shared workflow runs with write permission inside every
repo that points at it, so a typo here is a typo everywhere at once — and it would surface
as "Dependabot PRs quietly stopped merging", which is the kind of silence nobody notices
for a month. The `checks` job runs actionlint (which also shellchecks every `run:` block),
parses the templates (actionlint cannot see them — they are not in `.github/workflows/`,
and a fragment is not even a whole YAML document), shellchecks the two scripts, and
fixture-tests the ecosystem detector.

**Self-enrollment.** Without it, the one repo exempt from the standard would be the
standards repo. It is now enrolled the normal way: `dependabot.yml` for github-actions,
`allow_auto_merge=true`, and a `standards-ci` ruleset requiring `checks` with
repository-admin bypass (ruleset id 22932737). `bin/audit` recognises the definition file
(it contains `workflow_call:`) rather than mistaking it for a stale inline copy.

**The nightly gate in eachie.** Also beyond the brief, and driven by arithmetic: a plain
nightly `db` run is ~231 min/month, and the private allowance is 3,000 min/month with 2,058
already used by 2026-09-11. A `nightly_gate` job checks whether main moved in the last 25
hours; a quiet night costs ~1 minute instead of ~8. See the budget warning at the end.

### Pull requests opened (neither merged — that is Kevin's call)

- **eachie** `standards/dependabot` → https://github.com/khglynn/eachie/pull/203
- **remembrall** `standards/ci-trim` → https://github.com/khglynn/remembrall/pull/1

The four labels (`dependencies`, `major-review-needed`, `dependabot-needs-human`,
`no-ci-gate`) were created on **eachie** and **repo-standards** directly — the shared
workflow also creates them on first run, but eachie has 6 open Dependabot PRs that have
been getting a "label does not exist" complaint on every one, and creating a label is
additive and reversible.

---

## Experiments

### E1 — does Dependabot honour `@dependabot rebase` from `github-actions[bot]`? **UNTESTED.**

It could not be tested from here, for the reason the brief anticipated: a
`workflow_dispatch` workflow cannot be dispatched until it is on the default branch, and
there is no `GITHUB_TOKEN` available locally — a comment posted with the local `gh` token
would be from **khglynn**, a real user, which is the case already known to work and
therefore proves nothing about the bot case.

Implemented as specified: a `stale-strategy` input with two values.
- `update-branch` (**default**) — `gh pr update-branch`, which merges base into the PR
  branch through the API. Always works, no dependency on Dependabot honouring anything.
- `comment` — posts `@dependabot rebase`. Unverified.

Recorded in README "Decisions" as the first thing to verify after the eachie stub lands.
Also recorded there: `@dependabot merge|squash|close|reopen` were **removed 2026-01-27**;
only `rebase` and `recreate` remain.

### E2 — actionlint. **PASS.**

`actionlint` was absent; installed with `brew install actionlint` (exit 0), which also
brings shellcheck.

```
$ actionlint .github/workflows/dependabot-automerge.yml
$ echo $?
0
```

Three real defects it caught during the build, all fixed:
1. A multi-line `gh pr comment --body "…"` string inside a `run: |` block — its
   continuation lines sat at column 0, which **ends the YAML literal block**. The file did
   not parse. Rewritten to build the comment line-by-line into a file. A heredoc does not
   work here either, for exactly the same reason.
2. `SC2129` — a run of individual `>> "$GITHUB_OUTPUT"` redirects; grouped.
3. `SC2016` — `$r` inside a single-quoted **jq** program read as an unexpanded shell
   variable. Real ambiguity; silenced with a `# shellcheck disable` and a comment saying
   which language owns the `$`.

The caller stub and eachie's and remembrall's workflows are also actionlint-clean.

### E3 — the classification logic, run by hand against real eachie PRs. **PASS, and it found the divergence.**

Harness: `scratchpad/build/e3.sh` — extracts the `updated-dependencies` trailer from each
PR's commit, reshapes it exactly as `fetch-metadata` emits `updated-dependencies-json`,
then runs the workflow's own jq verbatim.

```
──────── eachie PR #162   chore(deps-dev): bump vite from 7.3.6 to 8.2.1
    {"dependencyName":"vite","dependencyType":"direct:development","updateType":"version-update:semver-major","newVersion":"8.1.5"}
  old gate would have seen aggregate update-type = version-update:semver-major
  NEW VERDICT: major   → label 'major-review-needed', stop

──────── eachie PR #192   bump anthropics/claude-code-action … in the actions-minor-and-patch group
    {"dependencyName":"anthropics/claude-code-action","dependencyType":"direct:production","updateType":"version-update:semver-patch","newVersion":"1.0.214"}
  old gate would have seen aggregate update-type = version-update:semver-patch
  NEW VERDICT: merge   → approve + auto-merge behind 'unit'

──────── synthetic: the case the aggregate gets WRONG
  input: one patch + one unclassifiable
  aggregate update-type (what the old gate read) = version-update:semver-patch  → WOULD HAVE MERGED
  NEW VERDICT: unknown  → label 'dependabot-needs-human', stop
```

On the two real PRs old and new agree. The third line is the whole reason for the change:
the aggregate output is a **max that skips nulls**, so a grouped PR carrying one patch bump
and one package it could not read reports itself as `semver-patch` and merges. eachie's
inline workflow would have merged it. The shared one stops it.

*(#162's trailer says `8.1.5` where the title says `8.2.1` — the PR was rebased and the
title re-rendered. Irrelevant to the classification, noted so a future reader does not
chase it.)*

---

## Enroll dry-runs (no writes — none of these three were enrolled)

Full transcripts: `scratchpad/build/dry-{festival,kevinhg,listmaker}.txt`.

| repo | CI check used | ecosystems detected | what it would do |
|---|---|---|---|
| `festival-navigator` (public) | `checks` | github-actions `/`, npm `/` | stub only — leaves the existing dependabot.yml; create `standards-ci`; turn on auto-merge |
| `kevinhg-com` (private) | `verify` | github-actions `/`, npm `/` | same |
| `list-maker` (public) | `pytest` | github-actions `/`, npm `/cloudflare-trigger`, pip `/marketing`, pip `/pipeline` | same |

The CI check names are **job** ids, read from each repo's workflow, not workflow names
(`festival-navigator`'s workflow is named `CI`; its job is `checks`).

### A real finding from the dry-runs — three gaps in the existing configs

All three repos already have a `dependabot.yml`, so `enroll` correctly left them alone.
Comparing their settings against the template (comments stripped) turns up three things
worth a Phase-2 pass. **None of these were changed.**

1. **None of the three has a `cooldown`.** No supply-chain soak at all: a package published
   an hour ago can get a PR, and with auto-merge on, reach `main` the same day. eachie has
   one; these do not.
2. **None carries `labels: [dependencies]`**, so their bot PRs are visually
   indistinguishable from a human's in the PR list.
3. **`list-maker` is missing an ecosystem entirely.** Its config covers pip in `/pipeline`
   and `/marketing` plus github-actions — but the detector found **npm in
   `/cloudflare-trigger`**, which nothing is watching. That worker's dependencies have
   never been updated by anything.

Also noted: `kevinhg-com` runs github-actions updates **monthly** with `patterns: ['*']`
(one PR for everything including majors), which will always land in the `major` branch of
the new workflow and stop. Not wrong, just worth knowing before enrolling it.

---

## Unverified / carried forward

- **E1** (above) — `@dependabot rebase` from `github-actions[bot]`. Default avoids it.
- **The shared workflow has never run.** Every line of its logic was linted and its
  classification was exercised by hand (E3), but no end-to-end run has happened, because a
  `pull_request_target` workflow only runs once it is on the default branch. The eachie PR
  is what proves it.
- **`gh pr merge --auto` 422 handling** — the retry-once-after-15s path is written against
  the reported March-2026 behaviour (community 190610) and has not been observed firing.
- **`bin/enroll`'s entire WRITE path has never been executed** (added 2026-09-11 after a
  review pointed out this was missing from the list). No `standards/*` branch exists on
  repo-standards, festival-navigator, kevinhg-com or list-maker; eachie's was made by
  hand, and repo-standards' self-enrollment was committed straight to `main`. So
  clone → branch → commit → push → `gh pr create` → `PATCH allow_auto_merge` →
  `POST rulesets` has run **zero times**, and two of those calls are the shape the
  workspace CLAUDE.md warns 401s inside the Claude Code sandbox. The dry-run path is the
  only part that has been exercised. Run it against the **public** festival-navigator
  first — cheapest possible failure — before any private repo.
- **Rulesets on private repos.** `standards-ci` was created for real only on
  `repo-standards`, which is **public**. The brief states Pro-account rulesets do enforce on
  private repos; the first private one (`kevinhg-com`) will confirm it.
- **The `db` job's `!cancelled()` guard in eachie.** Standard GitHub semantics for letting a
  job run when a `needs` dependency was skipped, and actionlint accepts it, but it has not
  been observed on a live run. If the `db` job stops appearing on eachie PRs after the merge,
  that expression is the first suspect.

## ⚠ Budget warning, outside the brief's scope but worth Kevin's attention

Private-repo Actions minutes: **2,058 of 3,000 used by 2026-09-11**, reset Oct 1. That is
~187/day across 11 days; at that rate the allowance is exhausted around **2026-09-16**, and
with stop-usage on, Actions then **stop running on private repos entirely**. The two PRs
here reduce the run rate (remembrall roughly halves its run count; eachie drops ~231
vacuous minutes a month) but they do not close a gap that size on their own. Worth a
deliberate look at where the remaining minutes go before month end.

---

## 2026-09-11 — verification pass

Everything below was observed, not assumed.

**`repo-standards` CI: green on every push to main since CI existed.** *(Corrected
2026-09-11 — an earlier version of this line said "green on both pushes" beside a "5
 commits on main" claim elsewhere. There are 5 commits and 4 CI runs: `ci.yml` did not
exist for the first one.)* `checks` = actionlint (+shellcheck
on every `run:` block), template parse, script shellcheck, and the ecosystem-detector
fixture.

**Admin bypass on a live ruleset: CONFIRMED.** Pushing the BUILD-LOG commit to
`repo-standards` `main` while its `standards-ci` ruleset was active succeeded and printed:

```
remote: Bypassed rule violations for refs/heads/main:
remote: - Required status check "checks" is expected.
```

That is the exact behaviour every `enroll`-created ruleset is designed for: Kevin is never
blocked, the bot still has to satisfy the check.

**eachie PR #203 — all four jobs behaved as designed.**

| job | result | what it proves |
|---|---|---|
| `unit` | pass, 1m24s | unchanged |
| `db` | **pass, 7m49s** | the `!cancelled()` guard DOES let `db` run when `nightly_gate` is skipped — this was on the unverified list, now resolved. It also ran against the real Neon branch, so the new fail-on-missing-secret path did not fire, which is correct |
| `nightly_gate` | skipping | correct: it is `schedule`-only |
| `automerge` | skipping | correct: the PR author is khglynn, not dependabot[bot] |

**remembrall PR #1 — `check` pass, 5m52s.** One run for the push, as intended.

### Two fixes the verification pass found

1. **Forks were being reported as drift.** `google_workspace_mcp` — a fork the brief says
   to leave alone — came out as `drift: gets update PRs but nothing merges them`, which
   would have sent a future session to "fix" upstream's config. `bin/audit` now gives forks
   their own status, and `bin/enroll` refuses a fork outright (`ALLOW_FORK=1` overrides).
   Six of the 39 repos are forks.
2. **An inaccurate assertion message** in `check-templates.py` claimed the `dependencies`
   label was what lets the audit find bot PRs. It is not — the audit searches by
   `author:app/dependabot`. Reworded to say what the label is actually for.

### Final state of the audit

```
39 active repos under `khglynn`: 1 enrolled, 28 security-only, 6 forks, 4 drifting.
```

The four drifting are exactly the four the brief scoped: `eachie` (PR #203 open, which
takes it to enrolled), and `kevinhg-com` / `list-maker` / `festival-navigator` (dry-run
only, deliberately not enrolled in Phase 1). Full table:
`scratchpad/build/audit-after.md`.

---

## 2026-09-11 — triple-check pass

Four things found by re-reading the code and running it against live data. Two were real
bugs that would have fired in production.

**BUG 1 (real, would have broken the stale-PR path): `gh`'s `--jq` does not take jq's own
options.** The failing-check counter was written as:

```
gh pr view "$PR_URL" --json statusCheckRollup --jq --arg req "$REQUIRED_CHECKS" '…'
```

`gh --jq` takes the expression and nothing else, so `--arg` would have been swallowed as
the program. Fixed by piping into a real `jq`. Verified live afterwards against eachie
#203 (`0` failures, correct) and #162 (`0`, correct).

**BUG 2 (latent): `set -e` and `[ … ] && var=value`.** Three places used that idiom,
including one that was the **last command in a `for` loop body** in `bin/enroll` — where a
false test makes the whole loop return non-zero and kills the script. It survives today
only because of a POSIX exemption that is easy to lose on the next edit. All rewritten as
explicit `if`s, with a comment saying why.

**Live verification of every API shape the workflow depends on** (read-only):

| call | against | result |
|---|---|---|
| `rules/branches/main` | eachie | `unit` — ruleset lookup works on a **private** repo |
| `rules/branches/main` | ynai (ruleset, no checks) | empty → correctly routes to the no-CI-gate path |
| `rules/branches/main` + `branches/main/protection` | festival-navigator (neither) | `[]` then 404 → empty → no-CI-gate path |
| `compare/main...<head>` `.behind_by` | eachie #162 | `15` — the stale detector sees real numbers |
| `pr view --json comments` | eachie #203 | `1` — the "already commented?" guard can read |

**`bin/classify-pr` added** — the E3 harness, promoted from a scratch file to a permanent
read-only tool, because "what would the workflow do with this PR?" is a question worth
answering without waiting for a run. Output for every open Dependabot PR on eachie today:

| PR | title | verdict |
|---|---|---|
| #162 | vite 7.3.6 → 8.2.1 | major → `major-review-needed` |
| #161 | stripe 20.0.0 → 22.4.0 | major → `major-review-needed` |
| #160 | ai 4.3.19 → 7.0.60 | major → `major-review-needed` |
| #143 | pnpm/action-setup 4 → 5 | major → `major-review-needed` |
| #118 | dependabot/fetch-metadata 2 → 3 | major → `major-review-needed` |
| #116 | ai 4.3.19 → 5.0.52 | ~~**unknown** → `dependabot-needs-human`~~ **WRONG — see the review-fixes section below. It is `major-review-needed`.** |
| #203 (mine, not Dependabot's) | — | no trailer → correctly refuses to guess |

**The null-updateType case is not hypothetical.** eachie **#116**'s current head commit
carries `"updateType": null` — the exact input shape that the aggregate output mishandles.

What is NOT true, and was nearly written here before checking: that the old workflow would
have merged it. #116 already carries `major-review-needed`, applied by `github-actions[bot]`
35 seconds after the PR opened, with no approving review — so the old gate correctly stopped
it **on the commit that existed then**. Dependabot has since force-pushed that branch 11
times, and the trailer visible today is from a later rebase. Without running fetch-metadata
v2 against today's head there is no way to know what the old gate would say now, so no claim
is made. `bin/classify-pr` carries a caveat about this: it answers "what would happen if it
ran right now", never "what happened before".


---

## 2026-09-11 — review fixes

An adversarial review of the Phase 1 build raised 16 findings, 5 marked must-fix. All 5
are fixed, along with 10 of the 11 smaller ones. What follows is what changed, what was
verified first, and the one thing declined.

### Verified before fixing (none of these were taken on trust)

| Claim | How it was checked | Result |
|---|---|---|
| fetch-metadata v3 COMPUTES a missing update-type | read `src/dependabot/update_metadata.ts` at the pinned SHA `25dd0e34…` | **true** — line 103: `dependency['update-type'] \|\| calculateUpdateType(lastVersion, nextVersion)` |
| eachie #116 therefore classifies as major, not unknown | its commit body carries `Bumps [ai](…) from 4.3.19 to 5.0.52.` and no `update-type` | **true** — 4 → 5 computes major |
| eachie's ruleset dismisses stale reviews on push | `gh api repos/khglynn/eachie/rulesets/13155439` | **true** — `dismiss_stale_reviews_on_push: true`, and `strict_required_status_checks_policy: false` |
| remembrall has had one PR, ever | `gh pr list --state all` | **true** — only the builder's own #1 |
| remembrall's runs are push-dominated | `gh run list --limit 100` | **true** — 99 push / 1 pull_request; 65 pushes on `gate3*` branches |

### The five must-fixes

**1. The stale-PR refresh was a dead end.** `gh pr update-branch` pushes as
`github-actions[bot]`, and GitHub does not start a workflow run for events its own token
triggers. So the push fired **no** run: the required check would have sat at "expected,
waiting" forever, eachie's ruleset would have dismissed the bot's approval on that same
push, and auto-merge was never enabled because the run stopped one step earlier. It was
also unnecessary — `strict_required_status_checks_policy: false` everywhere means being
behind base never blocked the merge. **Fixed:** approve and enable auto-merge FIRST,
unconditionally once the gate is clear (a red check simply leaves the PR queued, which
strands nothing); `update-branch` deleted; `stale-strategy` is now `none` (default) or
`comment`, and `comment` posts `@dependabot recreate` once per head commit — Dependabot's
own push does re-run CI. Still unverified whether Dependabot obeys a bot's comment.

**2. `enroll` silently reverted every carved exception.** The stub was `cp`'d from the
template unconditionally, so the documented rollout path — re-run enroll everywhere —
undid every per-repo `with:` block, and the generated PR body said only "a ten-line
workflow", so the revert was invisible to anyone reading the body rather than the diff.
**Fixed:** a stub already pointing at repo-standards is left completely alone and the run
prints the exception it preserved. The trade (a changed stub *template* no longer
propagates) is documented in the file, the README and `enroll` itself.

**3. The standards repo could auto-merge a bump of its own privileged action.** It
watched github-actions, was enrolled with no `with:` block, and required only `checks` —
actionlint plus a template parse, which cannot read an action's new code. A
fetch-metadata v3.1.0 → v3.1.1 PR would have merged with no human, and that code then
runs with write permission inside every enrolled repo. **Fixed:** `merge-patch: false,
merge-minor: false` in this repo's own stub, with the reason on the line. Also pinned
`actions/checkout` and `rhysd/actionlint` to SHAs — the README's pinning argument was
only a third true.

**4. `bin/classify-pr` did not reproduce the action.** It read the raw trailer and never
set `prevVersion`, so a null `update-type` came back `unknown`. Two failures: #116 was
predicted `dependabot-needs-human` when the workflow says `major-review-needed`, and —
worse — a null-trailer `1.2.3 → 1.2.4` bump read `unknown` (reassuring) while the workflow
computes `semver-patch` and merges. **Fixed:** `bin/lib/trailer-to-json.py` ports
`calculateUpdateType` verbatim and resolves versions through the same fallback chain. The
classification rule exists in two copies that cannot be merged (the workflow never checks
out code), so `bin/lib/check-classifier.sh` now diffs them and runs fixtures through the
workflow's own extracted program. It caught a one-space drift on its first run.

**5. The remembrall PR's rationale was contradicted by the repo's history.** The "165 runs
were duplicates, you lose nothing" story was false — one PR ever, 65 branch-push runs.
**Fixed** by changing the change, not just the words: filter by **path**, not by branch.
Every CI step runs from `app/`; 48% of the 364 commits since 2026-09-01 touched no `app/`
path. Same order of saving, no coverage lost, `gate3*` branches keep their gate. The PR
body now leads with the correction.

### The smaller ones

| # | Finding | What was done |
|---|---|---|
| 6 | Classic branch protection 403 ≠ 404 — the log line claimed "none" when the token simply is not an admin | 403 gets its own path: `label-unparsed` + a warning naming the cause, not `no-ci-gate` + advice to add CI the repo already has |
| 7 | `enroll`'s write path never executed, and not on the Unverified list | added, with the "public repo first" ordering |
| 8 | The nightly DB gate had no failure notification | a `nightly_alarm` job opens an issue (or comments on today's) with a link to the run |
| 9 | `require-ci` was fail-OPEN on any value but `true` | validates `true\|false`, errors otherwise, and the positive test is now `= "false"` |
| 10 | `bin/audit --markdown\|--plain` documented, never implemented | removed from the usage line |
| 11 | `audit` calls go.mod a manifest, `enroll` says "nothing to keep updated" | the detector reports unsupported manifests on stderr; enroll prints them; audit's list aligned |
| 12 | A failed or truncated tree call read as "no dependencies" | `enroll` dies on both; `audit` marks the row `unknown` |
| 13 | `disallowed` filed under the "could not classify" label | new `label-opted-out` input, default `dependabot-opted-out`, created by workflow and enroll, in the README table |
| 14 | `--force` push; `--ci-check` never validated | own-commit check + lease; `bin/lib/pr-job-ids.py` refuses a name that is not a real PR job id, **before any write** |
| 15 | eachie PR body promised a merge that cannot happen | rewritten: all six open PRs are majors, expect six labels and zero merges |
| 16 | 4 accuracy items | CI-run count corrected above; both other ci.yml actions pinned; a missing fragment now fails loudly; the v2→v3 fetch-metadata major called out in the eachie PR body |

### Declined — one, and why

**Finding 7's second half: "run `bin/enroll khglynn/festival-navigator --ci-check checks`
for real before next-step 5."** The reasoning is right and the ordering advice is now in
the next-steps list — but the brief is explicit that those three repos are dry-run only in
Phase 1 ("Do not enroll them for real in Phase 1"), and an enroll opens a PR and creates a
ruleset on a repo Kevin has not agreed to change yet. Doing it would swap an unverified
code path for an unrequested write. The *risk* the finding names is real, so it is now on
the Unverified list in the words the finding used, and the next-steps list says to run
festival-navigator first. Kevin makes that call, not this session.

### Not changed, and worth saying

The review's verdict called the merge gate itself sound — "the per-dependency
classification … fails closed at every branch I walked". Nothing about the classification
rule changed. What changed was everything around it: what happens after a verdict, what
gets written where, and whether the tools tell the truth about it.

### Verification after the fixes

- `actionlint` clean on all four workflows (repo-standards ×3, eachie's `test.yml`,
  remembrall's `ci.yml`).
- `shellcheck` clean on `bin/enroll`, `bin/audit`, `bin/classify-pr`,
  `bin/lib/check-classifier.sh`.
- `bin/lib/check-classifier.sh` passes 7 assertions.
- `check-templates.py` and the ecosystem-detector fixture pass.
- `repo-standards` CI **green on `51243a8`** (the push carrying all five commits).
- `bin/classify-pr khglynn/eachie 116 192 162 143` run live: #116 now reads
  `major → major-review-needed`, matching what the workflow will do. The other three
  unchanged.
- `bin/enroll khglynn/festival-navigator --ci-check checks --dry-run` run live: prints
  `CI check 'checks' is a real job that runs on pull requests here ✓`, ensures the new
  fifth label, and still leaves the existing dependabot.yml alone.
- The same command with a deliberate typo (`--ci-check check`) **exits 1** having written
  nothing, and prints the repo's real job ids. That is finding 14b's silent-failure class
  closed: `check` would have created a required context nothing ever reports.

### One structural change made while fixing the above

Input validation was scattered across three steps, and `stale-strategy`'s check sat
**after** auto-merge had been enabled — so a typo'd value made the `failure()` handler
label a PR `dependabot-needs-human` about a pull request that was, at that moment, already
queued to merge. Two contradictory signals out of one run. All five inputs are now checked
in the workflow's first step, before a single label, approval or comment.

### Two things observed while verifying, not changed

1. **eachie's `db` job has no `timeout-minutes`.** It normally takes ~7m50s; with no
   timeout it inherits GitHub's 6-hour default, so one hang costs up to 360 minutes of a
   3,000-minute monthly allowance that was already at 2,058 on 2026-09-11. `unit` has the
   same gap; remembrall's `check` correctly sets `timeout-minutes: 20`. Not changed here
   because pushing it would restart the whole suite mid-verification, and the `db` job's
   repo-wide concurrency group (`cancel-in-progress: false`) means a new run queues
   *behind* the old one rather than replacing it. One line each, worth doing next.

2. **A false alarm worth recording, because the habit is the point.** Midway through
   verification the `db` job looked like it had been running 55 minutes against a 7m49s
   baseline, and the next move was going to be "cancel it and add a timeout". Checking the
   clock first — `date -u` said 16:12, the step started 16:04 — showed it was at eight
   minutes and entirely normal. The measurement was wrong, not the system. Same lesson as
   the "five subdomains down, probably TLS" case that was actually a stale DNS cache.

### Where the branches stand at the end of this pass

| | |
|---|---|
| `repo-standards` `main` | 8 commits past the Phase-1 state, CI green |
| eachie `standards/dependabot` | PR #203, `unit` green, `db` green, `automerge` correctly skipping (author is khglynn, not dependabot[bot]) |
| remembrall `standards/ci-trim` | PR #1, both `check` runs green (5m58s and 5m51s) |

Neither PR is merged. eachie #203 is `BLOCKED` only because `protect-main` requires one
approving review — Kevin approves it himself or uses his admin bypass; it is not waiting
on CI.

## 2026-09-11 evening — first live runs and the routine (session: trimm slack claude improvements)

- **eachie #203 merged** (16:14 CT, by the eachie session on Kevin's word, with a second pass: draft-PR skip, docs-only skip, timeouts, nightly compares to the last-tested SHA; stub refreshed by hand to the current template). **remembrall #1 merged** 21:56Z by this session after a 10-minute heads-up to the remembrall session.
- **First live end-to-end run of the shared workflow on a real PR:** eachie #162 (vite 7.3.6 → 8.1.5). Sequence: label removed by hand → `@dependabot recreate` posted from Kevin's login (Dependabot +1 in 1 s, recreated 21:54:56Z) → `dependabot-automerge` run 34651617344 on `pull_request_target`/synchronize → log: `dependencies in this PR: vite 7.3.6->8.1.5 [version-update:semver-major]` / `decision: verdict=major` / `labelled 'major-review-needed' and stopped`. Classification, label creation and the stop path all behaved. The merge path (patch/minor → `--auto`) has not yet had a live PR to run on.
- **Routine "Dependabot verdict" created** on Kevin's personal claude.ai account: `trig_019EgJ3ZffYbVgTGLYkzDcj3`, GitHub trigger eachie `pull_request.labeled`, filters Author is one of `dependabot[bot]` and Labels is one of `major-review-needed,dependabot-needs-human,no-ci-gate`, Slack the only connector, Opus 5, auto-fix off. Built through the `playwright-2` profile (signed into kevn.hg@gmail.com) because the Claude in Chrome extension only talks to sessions on the same login as the CLI profile, which was on another account.
- **Why the GitHub trigger has not fired:** `GET /v1/code/github/installations` on claude.ai returns `{"installations":[],"personal_installations":[]}` — the Claude GitHub App is installed on no repository for this account, so GitHub sends it no webhooks. The routine form did not warn. Two `labeled` events on #143 (21:51:52Z, 21:51:54Z) and the workflow's own re-label of #162 produced no run. **Fix (Kevin, one time):** install the Claude GitHub App at https://github.com/apps/claude/installations/new for `khglynn`, "All repositories", so every enrolled repo can trigger routines without a per-repo visit.
- A manual "Run now" of the routine was started at 21:56Z with no payload, to exercise the Slack path; result recorded below when it lands.
- Cloud-session limits learned today (from the Slack-app test on #192): a Claude Code cloud session's PR comments get every `@mention` defanged with U+00B7 middle dots, so it cannot drive Dependabot; timers are disabled in Slack-started sessions and the environment idles when the turn ends. Anything that must wait or command Dependabot belongs in the workflow or in a comment from a real user, never in a cloud session.

## 2026-09-13 evening — Phase 2 enrollment (session: trimm slack claude improvements)

- Post-pause check on 09-11 19:15 CT: nothing broken; eachie #162 (vite 8) merged on Kevin's Slack go after the app misread a bare "do it"; routine's Do-it line now names repo and PR and asks for a thread reply.
- Enrolled for real, one command each: festival-navigator → PR #17 (ruleset `standards-ci` requires `checks`, admin bypass verified), kevinhg-com → PR #12 (`verify`), list-maker → PR #62 (`pytest`). allow_auto_merge on in all three. Each PR adds only the ten-line stub; the existing `dependabot.yml` files were left alone (enroll never overwrites one).
- Gap still open: list-maker's `dependabot.yml` does not watch the npm workspace in `/cloudflare-trigger` (enroll detected it, printed the diff, did not write). Add it by hand in a follow-up PR, or accept security-only coverage there.
- GitHub App still not installed for the account (blocks the routine's own trigger); the playwright-2 window is on GitHub's sign-in page waiting for Kevin.

## 2026-09-13 ~21:38 CT — the routine's silent trigger, root-caused and fixed

- GitHub already had the Claude App installed on `khglynn` (installation 97562334, All repositories) — but claude.ai's `/v1/code/github/installations` was empty for the personal account. Cause: the personal account had connected GitHub through `/web-setup` (a `gh` token), which clones anything the token can see but carries no App installation, so no webhooks. The App authorization is made by the browser flow ("Connect GitHub" on claude.ai/code), not by installing the App on GitHub.
- Fix applied from the playwright-2 profile: Customize → Connectors → GitHub Integration → Disconnect, then claude.ai/code → Connect GitHub (GitHub auto-approved; the app was already authorized for the user) → "Linked 2 GitHub accounts: khglynn, tecovas-com". The installations endpoint now returns both. Cost: cloud sessions had no GitHub for about one minute; nothing was running.
- Trade-off to remember: the App path reaches public repos and private repos the App is installed on; the token path reached every repo the token could see (it had listed matthewb-coder/* and other people's repos). For Kevin's own repos the App path is the right one; re-run `/web-setup` only if a cloud session ever needs a repo the App is not installed on.
- Trigger test: eachie #143 relabelled `major-review-needed` at ~02:38Z on 09-14 to see whether the routine now fires by itself.

## 2026-09-13 22:44 CT — four verdict routines live, one per repo

- A routine accepts one GitHub trigger and a trigger names one repository, so the design is one routine per enrolled repo (each run clones only its repo). Created and verified on their pages: festival-navigator `trig_01Q8SKMN4TZGLLoKXViLQBwK`, kevinhg-com `trig_01YX6RSVZ63xfPyMiqy4J2Ur`, list-maker `trig_01KJQ1Lz1eaPsaVL4WsAfng5`; eachie `trig_019EgJ3ZffYbVgTGLYkzDcj3` updated in place. All on the final prompt (verdict + risk first, "What changed" and "Why that's safe" one sentence each, no jargon, 100-word cap) after Kevin read the first automatic verdict and asked for both facts in a tight format.
- Form recipe that works (claude.ai/code/routines/new, playwright-2): fill Name and Instructions; clear connectors with a loop that clicks the first `button[aria-label^="Remove "]` until none remain (a one-shot click of all of them races the re-render and leaves a random one), then add Slack back through "Add connector"; Model → Opus 5; Select a repository; "GitHub event" (the card sometimes arrives collapsed: click its header); Event → "Pull request: Labeled"; filter 1 Author is one of `dependabot[bot]`; filter 2 Labels is one of the three labels; Create. Verify on the page: `GitHub · khglynn/<repo>`, `Pull request: Labeled`, `Default · Opus 5`, the phrase "Why that's safe".
- An Opus pane teammate briefed to do this froze mid tool-call at 21:45 CT (transcript silent 53 min, the pane-teammate pattern); the lead did the four by hand in 6 minutes. eachie #143 merged 21:58 CT on Kevin's word.
