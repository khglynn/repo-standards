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
- 23:41 CT: Kevin said merge; festival-navigator #17, kevinhg-com #12 and list-maker #62 merged (list-maker via admin bypass: it carries a pre-existing one-approval rule like eachie, which the shared workflow satisfies with its own approve step). `@dependabot recreate` posted on every open Dependabot PR in the three repos to run the chain end to end: workflow → label or auto-merge → routine → #dependabot.

## 2026-09-14 00:00 CT — first live merges in the new repos, and the switch enroll was missing

- After `@dependabot recreate` on the four open PRs (kevinhg-com #11; list-maker #59, #60, #61), every run classified correctly (`verdict=merge`, patch bumps, gate `pytest`/`verify`) and enabled auto-merge — but none merged: `gh pr review --approve` failed with "GitHub Actions is not permitted to approve pull requests", and the step's `|| echo "already approved"` hid it. Cause: the per-repo Actions setting `can_approve_pull_request_reviews` was false on all three new repos (true on eachie, which is why eachie worked). With list-maker's one-approval rule, the PRs would have sat queued forever.
- Fixed live: PUT `actions/permissions/workflow` with `can_approve_pull_request_reviews=true` on festival-navigator, kevinhg-com, list-maker and repo-standards; re-ran the four runs; all four PRs approved by github-actions[bot] and merged 04:44–04:46Z.
- Fixed in the standard: `bin/enroll` step 6b sets the switch (idempotent, dry-run aware); the workflow's approve step now checks for an existing APPROVED review by github-actions on the current head and otherwise approves and FAILS LOUDLY (`::error`) instead of pretending it was already approved. `PR_NUMBER` added to that step's env. actionlint and shellcheck clean.
- Not yet covered: an audit column for this switch (fold into repo-standards#1).

## 2026-09-14 overnight — `bin/audit` Phase 2 (session: audit-phase2 builder, Opus 5)

Brief: `claude-plans/dependabot-verdicts/brief-audit-phase2.md`, spec `khglynn/repo-standards#1`.
Banking as I go; this section grows downward and the findings land here before the commits do.

**Environment confirmed before starting:** `gh` authed as `khglynn` (scopes `admin:org, gist, repo,
workflow`), PyYAML 6.0.3, `actionlint` and `shellcheck` both present.

**Sizing call made first, because it changes the design.** `GET /actions/runs?created=>=2026-09-01`
returns 416 runs for eachie alone; across all 41 active repos it is ~1,320, and the minutes estimate
needs one `/timing` call per run. Serial, inside the existing bash loop, that is 20+ minutes. So the
per-repo Actions work moved into one concurrent Python helper that runs once for every repo before
the bash loop, and the loop reads its JSON. `bin/audit` stays read-only: the helper issues GET and
nothing else.

### What got built

| File | What |
|---|---|
| `bin/lib/workflow-hygiene.py` | The two Actions warnings — jobs with no `timeout-minutes`, and the push+pull_request double run. PyYAML, with a regex fallback for hosts without it. |
| `bin/lib/actions-scan.py` | Everything per repo that needs the Actions API — the approve switch, the minutes estimate, the workflow files — done concurrently, GET only. |
| `bin/lib/render-audit.py` | The three output shapes: the table, `--json`, `--digest`. |
| `bin/lib/check-workflow-hygiene.sh` + `bin/lib/fixtures/workflow-hygiene/` | 15 fixture assertions, in CI. |
| `bin/lib/check-audit.sh` + `bin/lib/fixtures/audit/` | 17 assertions on the tree predicate and the digest's wording, in CI. |
| `bin/audit` | The columns, the modes, the preflight, and the truncation fix below. |
| `routines/weekly-digest.md` | The Monday-morning routine's prompt and form values. |
| `README.md` | "What the weekly digest tells you", plus one line per new column. |

### The bug that was already there: the audit had been lying for three days

`bin/audit` decided whether a repo's file list was readable with
`jq -r '.truncated // "err"'`. **jq's `//` treats `false` as empty, exactly like null** —
and `"truncated": false` is the good answer. So every repo, on every run, came back
`unknown: could not read this repo's file list (API error or truncated tree)` while the
table printed in full and looked completely normal. It shipped 2026-09-11 in `cd917d9`,
which was itself the fix for review finding 12 (the opposite failure: a truncated tree
reading as "no dependencies"). Nobody re-read the status column afterwards.

Fixed to `if type=="object" and has("truncated") then (.truncated|tostring) else "err" end`,
put on its own named line (`TREE_STATE_JQ`) so `bin/lib/check-audit.sh` extracts and runs
the real program rather than a retyped copy — the same trick `check-classifier.sh` uses
for the classification jq. All three cases are pinned.

Before: `0 enrolled, 0 security-only, 0 forks, 0 drifting, 40 unreadable`.
After: `5 enrolled, 29 security-only, 6 forks, 0 drifting`.

### How the minutes are counted, and the two measurements that decided it

**`billable` in `/actions/runs/{id}/timing` is all zeros on this account.** Every
`total_ms: 0`, every `job_runs[].duration_ms: 0` — on private repos as well as public, on
completed successful runs (eachie, kevinhg-com, repo-standards, checked by hand). Reading
the field whose name says "billable" would have reported 0 minutes used, for ever,
confidently.

**Wall-clock per run (`run_duration_ms`, which the brief specified) reads low — and the
first measurement of how low was wrong.** eachie's 100 most recent runs put wall-clock
within 1% of a real per-job figure, which looked conclusive. Widening to every private
repo for 09-01..09-11 (655 runs) gave **2,573 wall-clock against 2,962 per-job — 15%
apart**. The first sample happened to be runs that put nothing in parallel; a run whose
jobs overlap bills the sum and measures the max. For a number whose whole job is to warn
before a budget runs out, 15% low is the wrong direction, so the method changed.

**What it does now:** each job's `started_at` → `completed_at` from
`/actions/runs/{id}/jobs`, rounded **up to the whole minute** the way GitHub bills,
skipped jobs excluded, times the runner multiplier read from the job's labels (Linux 1x,
Windows 2x, macOS 10x). Same call count as the timing endpoint, larger responses.

**Hand-check, as the brief asked.** `kevinhg-com`, 41 runs this month, estimate 49
minutes. Three runs read by hand: `verify` 56s, `automerge` 9s, `verify` 55s → 3 billed
minutes for 120 seconds of work, because every job that runs at all costs a whole minute.
That is exactly the behaviour that makes a wall-clock sum (2 minutes) wrong. A second,
independent cross-check on the same repo — summing `updated_at - run_started_at` straight
off the runs list — gave 27.1 minutes against the timing endpoint's 27, so the two
wall-clock paths agree with each other and both sit below the billing rule, as they should.

**Against the one real invoice number available:** GitHub's billing page read 2,058 private
minutes at some point on 2026-09-11 (BUILD-LOG, 2026-09-11). This method gives 1,776 for
09-01..09-10 and 2,962 for 09-01..09-11, so a mid-day-11 snapshot falls inside the bracket.
Corroboration, not proof. The billing endpoints would settle it and are deliberately not
called: they need a classic token with the `user` scope, and minting one so a read-only
monitor can see one number is a worse secret than the problem (repo-standards#1 agrees).

### The API budget, and the second way this tool learned to lie

A full run is **~1,600 API calls, a third of GitHub's hourly 5,000**, almost all of it
measuring minutes. Weekly, that is free. Iterating on it is not — this session exhausted
the hour twice.

The first exhaustion looked like a hang: `bin/audit` sat for fifteen minutes with no
output, because the client slept whenever a response said `X-RateLimit-Remaining: 0`,
which is right for a brief throttle and catastrophic for the hourly one. Now the retry has
a bounded sleep budget and an exhausted hourly limit fails fast.

The second was worse and is the more useful finding. **`GET /rate_limit` reported
`remaining: 5000, used: 0` while every real call returned 403 "API rate limit exceeded for
user ID 19673024" — and the 403's own headers said `Remaining: 0, Used: 5000`.** The
endpoint reports a token bucket; the throttle that actually bites is applied at the user
level across every tool on the machine. A wait-loop that trusted `/rate_limit` released
early, and the audit then produced a complete, well-formatted, entirely empty report: all
forty repos reading "could not read this repo's file list", zero minutes everywhere,
`0 of 40 repos keep themselves up to date`. Nothing errored. Nothing looked wrong.

Two fixes, because one was not enough:
1. The remaining budget is now read from **a real call's response headers** (`GET /user`),
   never from `/rate_limit`.
2. `bin/audit` **preflights** and refuses to start when the budget is gone, printing when
   to come back, instead of spending an hour producing a confident lie:
   `GitHub's hourly API budget is used up (0 calls left). This audit needs about 1,600.
   Come back after 03:42 and run it again.`
3. And the digest now collapses more than two unreadable repos into one line, because
   forty identical "could not read" lines is not a Slack message.

### Two workflow-hygiene details the naive checks get wrong

- **A reusable-workflow caller may not carry `timeout-minutes`** — GitHub rejects the
  file. Every enrolled repo has exactly such a job (the ten-line stub), so a checker that
  did not skip them would warn on every enrolled repo for ever with no legal way to clear
  it. Skipped, with a fixture pinning it.
- **`push` on tags only, alongside `pull_request`, is not a double run.** A commit on a
  pull-request branch is not a tag push. Fixture pins that too, along with the correct
  shape (`push` restricted to the default branch), which must stay silent or the warning
  fires on this repo's own `ci.yml` and gets tuned out.

## 2026-09-14 02:27–07:05 CDT — Codex fixes landed, the final verdict shape proven, the builder resumed

(Clock note: the stamps written earlier tonight in `claude-plans/dependabot-verdicts/` say "00:2x CT"; the machine clock and the commit times put those events at 02:2x CDT. The lead's earlier notes were two hours early.)

- **02:27** Codex (`cx-20260914-022445`) returned SHIP WITH CHANGES on the approve-step change; all four applied in f321bef. (1) The step re-reads the PR's live head and stops if it moved since the event, and the approval is created with `commit_id` pinned to the classified head (`POST pulls/{n}/reviews`), so it can never bless a push that arrived mid-run. (2) The "already approved" check matches `github-actions[bot]` with `type == Bot` exactly; the old substring test would have accepted a human named `github-actions-fan`. (3) The review scan paginates (`--paginate --slurp`, `.[][]`) instead of reading the oldest 30. (4) `bin/enroll` sends only `can_approve_pull_request_reviews=true`; the old PUT also forced `default_workflow_permissions=read`, which would have silently downgraded a repo whose workflows rely on the write default. Verified live on list-maker: the narrowed PUT left `default_workflow_permissions` exactly as it was.
- **02:33** The final seven-line verdict shape observed on a real PR for the first time. eachie #161 (stripe 20.0.0 → 22.4.0, tests failing) was relabelled from Kevin's login at 02:32:59; the eachie routine fired by itself and the verdict landed in #dependabot at 02:33:57: "Verdict: Merge after a fix. Risk: medium." / "What changed: The new version talks to Stripe using a newer payment interface than the one the app asks for." / "Why that's safe: This is the code that charges customer cards, so it needs a one-line update and a real payment test." / "Tests: failed: the app asks for an older Stripe interface the new version no longer allows." / "To act: reply here with @Claude fix and merge eachie #161". Plain English, under 100 words, no angle brackets. Acceptance criterion 4 met.
- **03:09** The overnight builder (Opus, Workflow `wf_93c9ffd8-17e`) died on the account's session limit (reset 06:50 CDT) with nothing lost: every deliverable committed and pushed, 9f1b27e through 4ff140d — the approve/minutes/timeout/double-trigger columns, `--digest`, the concurrent Actions scan, the API-budget preflight, the CI fixtures, the README section and `routines/weekly-digest.md`. What it never finished: one complete full `--digest` run pasted here (the hourly API budget was gone twice), the by-hand minutes check, and its return summary.
- **06:55** Lead's spot-check, `bin/audit --digest --skip-actions`, ran clean in 83 s: 5 of 40 repos enrolled, 12 update pull requests waiting, oldest 26 days (eachie #160/#161), ynai 4, recordOS 3, ai-orchestrator / okta-mcp-server / spotify-bulk-actions-mcp 1 each. One defect: it printed "about 0 minutes of the free 3,000" for a measurement it skipped. A skipped measurement must read as not measured, never as zero — handed to the resumed workflow as the first thing to fix.
- **07:05** Resumed as Workflow `audit-phase2-resume` (Opus finisher → Opus adversarial reviewer → Opus fixer → Sonnet verifier), with one rule added to every stage: a full audit costs ~1,600 of GitHub's 5,000 hourly calls and the budget is shared, so at most one full run per stage and `--cap 30` otherwise.

## 2026-09-14 07:05–08:0x CDT — the resumed stage: the confident zero, and a method error the hand-check caught

Picked up from the 03:09 death. Everything the overnight builder committed was intact; this
stage fixed what it had left, then found one thing nobody had looked for.

### 1. The confident zero (the lead's 06:55 finding) — fixed first

`bin/audit --digest --skip-actions` printed **"about 0 minutes of the free 3,000 (an
estimate). At this rate the month ends near 0, inside the free pool"** for a measurement it
had never taken. Third instance of this repo's signature bug: a confident sentence standing
in for an absent fact, in the output a person reads without checking — and this one reads
as *good news*.

Zero and absent are now different values end to end. `bin/audit` passes `method=skipped`
for `--skip-actions` (distinct from `none`, meaning the scan failed); `minutes_picture`
returns `measured=False` with `private`, `public`, `daily` and `projected` all `None`
rather than zeroes that format beautifully; the digest says *"Build time was not checked
this week, so there is no figure and no run-out date — not a zero"*; the table says **NOT
MEASURED**; `--json` carries `minutes_measured`.

**The part that was easy to miss.** A skipped Actions pass also disables the approve-switch
drift rule, because both read the same scan. So a skipped run reports **fewer** problems
than a real one — on the fixture, 2 of 4 enrolled where the full run says 1 of 4. The
digest now says so out loud: *"a repo could be half set up in a way this message cannot
see."* An unchecked week and a clean week are indistinguishable unless the message says
which one it was.

Same rule applied one level down, where `check-workflow-hygiene.sh` already claimed
`bin/audit` printed which YAML parser ran (it did not): the regex fallback answers the
time-limit question and **declines** the double-trigger one, so an empty list on that path
means *not checked*, not *none found*. Both outputs now name the parser and say what its
silence means.

### 2. The by-hand minutes check found a method error, not a rounding one

The brief asked for one repo's minutes checked by hand against `gh run list`. Chose `ynai`
— private, 20 runs, small enough to read every one.

Per-job by hand: 11 of the 20 runs were `Claude Code` runs that concluded **skipped** (no
charge), and the other 9 were `Dependabot Updates`, each one job of 51–114 seconds,
billing 1–2 whole minutes. **Hand total 15 minutes; the audit's column said 15.** The
arithmetic was exactly right.

And exactly wrong, because **GitHub does not bill those runs at all.** "Running Dependabot
on standard GitHub-hosted and self-hosted runners does not count towards your included
GitHub Actions minutes" — [GitHub Docs, *Dependabot on GitHub Actions
runners*](https://docs.github.com/en/code-security/concepts/supply-chain-security/about-dependabot-on-github-actions-runners),
read 2026-09-14. ynai's real September cost is **nil**. A hand-check that only re-does the
tool's own arithmetic would have blessed this; the check that caught it was asking what the
runs *were*.

Excluded at run-list time by `path` starting `dynamic/dependabot/` — the only field that
separates Dependabot's own run from **a repo's CI running on a Dependabot pull request**,
which *is* billed and whose exclusion would push the error the other way (verified against
ynai run 34538498192). `free_runs` counts what was left out so the run count stays honest.

**Known exception, unhandled and named in the code:** on *larger* runners GitHub bills
Dependabot normally. Telling them apart needs the per-run jobs call this exclusion exists to
skip, and every repo here is `ubuntu-latest`. The table's "non-Linux runners seen" note is
the tell if that changes.

### 3. Two defects in the overnight code, both found by real data rather than fixtures

- "could not be measured" fired on four repos whose *only* run this month was a free
  Dependabot one. `runs and not timed` cannot tell **excluded** from **unread**. Now asks
  whether any *billable* run went untimed.
- A partial reading **suppressed the run-out date**, which is backwards: an incomplete count
  is a floor, so the date moves *earlier*. The date is now always printed, followed by
  "that date could be sooner".

### 4. The one full run, and the correction

Budget checked first (4,659 of 5,000 left), then **one** full audit at 07:06–07:10 CDT,
3 min 38 s, run as `--json` so the digest and the table could both be rendered from a single
spend. 40 repos: **5 enrolled, 29 security-only, 6 forks, 0 drifting, 0 unreadable.**

Its `--digest`, exactly as printed (this is the pre-correction number — Dependabot's own
runs are still counted here):

```
*Dependency check — 14 Sep 2026*

5 of 40 repos keep themselves up to date. 12 update pull requests waiting, the oldest 26 days old.
Build time on the private repos this month: about 2550 minutes of the free 3,000 (an estimate). At this rate the free minutes run out around 16 Sep.

- ynai — 4 update pull requests waiting, oldest 4 days.
- recordOS — 3 update pull requests waiting, oldest 2 days.
- eachie — 2 update pull requests waiting, oldest 26 days.
- ai-orchestrator — 1 update pull request waiting, oldest 2 days.
- okta-mcp-server — 1 update pull request waiting, oldest 2 days.
- spotify-bulk-actions-mcp — 1 update pull request waiting, oldest 2 days.

Also: 27 build jobs across 11 repos have no time limit, so one stuck job could burn six hours of the free pool.
Also: 4 repos run their tests twice for every change (once for the branch, once for the pull request), which may be on purpose.
Note: eachie had more runs this month than were measured, so the minutes above are low.

To act: the oldest waiting update is in eachie, 26 days old — open it and merge or close it.
```

Then the private half — 22 repos, 67 s, not a second full audit — re-measured with the
exclusion in place. Private total **2,550 → 2,515**. Small in aggregate because eachie
(1,292, capped at 300 of 453 runs) and remembrall (1,193) dominate, but `ynai` 15 → 0,
`kevinhg-com` 49 → 30, and `AIOpsSurvey` / `wkt` / `sync-bot` / `holting-safely` all → 0.
The corrected digest, same renderer, same run's rows with the private repos re-measured:

```
*Dependency check — 14 Sep 2026*

5 of 40 repos keep themselves up to date. 12 update pull requests waiting, the oldest 26 days old.
Build time on the private repos this month: about 2515 minutes of the free 3,000 (an estimate). At this rate the free minutes run out around 17 Sep.

- ynai — 4 update pull requests waiting, oldest 4 days.
- recordOS — 3 update pull requests waiting, oldest 2 days.
- eachie — 2 update pull requests waiting, oldest 26 days.
- ai-orchestrator — 1 update pull request waiting, oldest 2 days.
- okta-mcp-server — 1 update pull request waiting, oldest 2 days.
- spotify-bulk-actions-mcp — 1 update pull request waiting, oldest 2 days.

Also: 27 build jobs across 11 repos have no time limit, so one stuck job could burn six hours of the free pool.
Also: 4 repos run their tests twice for every change (once for the branch, once for the pull request), which may be on purpose.
Note: eachie had more runs this month than were measured, so the minutes above are low.

To act: the oldest waiting update is in eachie, 26 days old — open it and merge or close it.
```

**The 3,000-minute warning survived the correction**, which is the thing worth knowing: it
is a real warning, not an artefact of counting free runs. Two private repos are spending it
— and eachie's figure is a floor, since only 300 of its 453 runs were measured.

### What stays unverified

- **The account-wide total after the exclusion has not been measured in one pass.** 2,515 is
  the full run's public rows plus a private-only re-measure taken four minutes later. The
  public repos' minutes in that table still count their Dependabot runs; they are free and
  excluded from the 3,000 either way, so no printed total is affected — but the next full
  run is the first clean one.
- **No figure here has been checked against a GitHub invoice.** The billing endpoints need a
  classic token with the `user` scope and are deliberately not called. The one real data
  point remains the billing page's 2,058 private minutes read on 2026-09-11, which brackets
  correctly and is corroboration, not proof.
- **eachie is capped**, so its 1,292 is low by whatever the 153 unmeasured runs cost.
- **The weekly routine has still never been created.** `routines/weekly-digest.md` carries
  the form values, and the schedule card in that form remains the one part of the recipe
  nobody has filled in on screen.
- **The digest has never been posted to Slack by the routine** — every digest so far has
  been read in a terminal.
- The larger-runner Dependabot exception above.

### One finding for the lead, left untouched under tonight's rule

The full run's warnings open with **this repo's own shared workflow**:
`repo-standards: no time limit on dependabot-automerge.yml:automerge`. That is the file
that runs, with write permission, inside every enrolled repo — so the one job in the
account that most wants a ceiling is the one without one, and a hang there inherits
GitHub's six-hour default in whichever repo it happens to be running in. The brief forbids
editing `.github/workflows/dependabot-automerge.yml` tonight (Codex had it), so it is
recorded and not touched. It is a one-line change (`timeout-minutes:` on the `automerge`
job, line 96) whenever that lock lifts.

### Closing note

Finished this stage: the not-measured fix and its fixtures, the parser reporting, the
Dependabot-run exclusion with the re-measure behind it, the two defects above, the README
and routine-prompt updates, the one full run pasted here, and the by-hand check. Local CI
is green end to end — `actionlint`, `shellcheck` over all six scripts, `check-audit.sh`
(now 5 sections), `check-workflow-hygiene.sh`, `check-classifier.sh`, `check-templates.py`,
the ecosystem detector. GitHub API budget left at the end of the stage: about 2,400 of
5,000.

## 2026-09-14 07:20–08:0x CDT — the review stage: nine defects, and the two that were still reaching Slack

The resumed stage's fix for the confident zero was real but partial. An adversarial review
(one `--digest --skip-actions` run, no full audit) found the same sentence still reachable
three other ways, a parser that finds nothing on ordinary workflow files, and a CI fixture
due to start failing on 27 September. Every finding below was reproduced against the
shipped code before it was changed, and again after.

### 1. The confident zero had three more doors, not one

`measured` was keyed on the *method*, so a run that skipped nothing could still print
**"about 0 minutes of the free 3,000 (an estimate). At this rate the month ends near 0,
inside the free pool"** whenever:

- **no private repo was visible at all** — a repo-scoped token in the cloud routine sees
  none of them, `private` sums to 0 over an empty list, and the sentence reads as a quiet
  month;
- **every private repo's Actions scan failed** — the same sentence, with a contradicting
  "4 of the 4 repos could not be measured" underneath it. The first half still reads as
  good news, which is the failure this stage existed to end.

The question is now asked of the *data* rather than the flags: were any private repos
measured, and did any repo with billable builds get one of them timed. Both answers carry
a `reason` (`skipped`, `none`, `invisible`, `unread`) and the table says which. A month
whose private repos genuinely ran nothing billable is still a real zero — that is a
measurement, not an absence — and an owner with no private repos at all is not
"unmeasured" either.

**And the same sentence had a tense problem.** Spending past the allowance printed the
run-out date in the future: 3,500 minutes read on 14 September announced "the free minutes
run out around 12 Sep". One line of arithmetic settles when that can happen — the
projected date is `start + ALLOWANCE/daily`, today is `start + elapsed`, and
`daily = private/elapsed`, so the date is behind today *exactly* when the allowance is
already spent. So there is no "the date has passed but the pool is not gone" case, one
branch covers it, and `render-audit.py` carries the arithmetic so nobody re-adds a second
one for a past date. (The review proposed two branches; the second is unreachable.)

### 2. The regex parser found nothing on any normally-written workflow

`workflow-hygiene.py`'s PyYAML-free fallback — **the path a cloud routine takes** — asked
`^\s+uses:` at any indentation. A job written in the ordinary style:

```yaml
  unit:
    runs-on: ubuntu-latest
    steps:
      - name: Check out
        uses: actions/checkout@v5
```

matched on its *step's* `uses:`, was read as a reusable-workflow caller, and was skipped in
silence. The mirror bug let a *step-level* `timeout-minutes:` satisfy the job-level check
it is not. Between them that is most real workflows: the weekly digest would have reported
"no repos have this problem" forever. Both questions are now anchored to the job's own key
column.

Two fixtures reproduce it (`steps-with-uses.yml`, `step-level-timeout.yml` — proved against
the old code, which returned `[]` for both), and **every** timeout fixture now runs through
*both* parsers. Testing one engine per fixture is what let this through.

### 3. Two more absent-versus-false bugs in `bin/audit`, both reported as drift

The same shape this repo already documents twice, one call further on:

- A 403, 5xx or rate-limited read of a repo's merge-rules workflow leaves `content` empty,
  both `grep`s miss, and the row falls through to **"drift: still has its own private copy
  of the merge rules"** — about a file it never read. The tree call having succeeded is
  what makes it invisible.
- `auto_merge="?"` on any failure of `GET repos/{r}`, tested with `!= "true"`, becomes
  **"drift: repo setting 'allow auto-merge' is off"** about a setting nobody read. That one
  only reaches repos that got everything else right, since a repo needs both the stub and
  `dependabot.yml` to reach that line.

Both now read `unknown: …`, which `counts()` already files as unreadable rather than clean.

### 4. The digest promised under 150 words and was 202

`routines/weekly-digest.md` said "Under 150 words in total" and, four lines earlier, "use
its numbers exactly as printed and do not recompute them" — a routine obeying both had to
silently drop repo lines, which is the one thing this message exists not to do. The real
14 Sep output was 202 (`wc -w`), and nothing checked it: the only length assertion was on
the headline.

Fixed on both sides. The prompt now says *post what the audit printed, unchanged*, and
keeps the writing rules for the hand-written fallback only. The renderer **enforces** the
cap instead of aiming at it: it assembles the message, and while it is over 150 words the
repo list gives way — five lines at most, and fewer if the notes need the room — saying out
loud how many repos it left out. The notes never give way, because a note that vanishes
reads exactly like a week with nothing to report. A fixed five-line cap was tried first and
still landed at 154; the enforced version absorbs a later note (an unreadable build file,
say) instead of walking back over the line in the one output nobody re-measures.

Wording was tightened to buy the room honestly rather than by dropping facts: the per-repo
lines lean on the headline's "12 updates waiting" instead of repeating "update pull
requests waiting" six times, and "To act:" stopped restating a drifter's whole diagnosis
one line after the body printed it.

### 5. A CI fixture that was going to start failing on 27 September

`check-audit.sh`'s BIG case pins 2,600 minutes against `--since 2026-09-01` and asserts a
run-out date — but the projection divides by *real* elapsed days, so `2600/elapsed × 30 >
3000` only holds while fewer than 26 days have elapsed. Moving `--since` back to 1 July
makes the same row print "the month ends near 1067, inside the free pool" and both
assertions fail. `render-audit.py` now takes `--today`, and every assertion in
`check-audit.sh` pins `--today 2026-09-14`, which also makes sections 2 and 5 deterministic
rather than merely currently-true.

### 6. Smaller things, all taken

- **An unreadable build file reached the table and not the digest.** Silence in the digest
  means clean, which is the rule the rest of this stage was built on. It now gets a note.
- **"To act:" named `drifters[0]`** — `gh repo list` order — so it could name an arbitrary
  drifter while a worse one went unmentioned. Sorted the way the body is.
- **The preflight refused below 200 calls whatever the flags said**, while explaining that
  "this audit needs about 1,600". So `--skip-actions` and `--cap`, the two escapes the
  README recommends for a short budget, were blocked by a threshold set for a run nobody
  asked for. It now costs out the run in front of it (`--need`) and names both cheaper
  commands in the refusal.
- **Once the hourly budget is gone, the scan stopped issuing ~1,500 requests that cannot
  succeed** — each one was a real call that 403'd and spent the next hour's budget.
- **`capped` fired on a repo with exactly `cap` completed runs and nothing left over** — a
  complete, correct reading labelled "⚠ capped" in the table and called out in the digest
  as a figure to distrust. It now means what it says: builds went unmeasured.
- **Self-hosted runners billed at the Linux rate.** GitHub bills none of their minutes, so
  counting them inflates the one number this tool exists to warn about, on exactly the
  repos that moved work off GitHub's runners to stop paying for it. `SELF, 0`, with its own
  note rather than being filed under "non-Linux".
- **`_is_free_dependabot_run` had no test** — the predicate that moved the account's
  headline figure by 35 minutes and can silently zero real billed minutes if GitHub's
  `event`/`path` shape drifts. Three run shapes and the five runner labels are now pinned.
- **Jargon:** "runs" → "builds" in the digest, and "1 of the 1 repos could not be measured"
  is pluralised.

### What was declined, and why

- **`.github/workflows/dependabot-automerge.yml:96` still has no `timeout-minutes`.** The
  audit's own first warning, on the one job in the account that most wants a ceiling — it
  runs with write permission inside every enrolled repo. The brief forbids editing that
  file and `templates/caller-stub.yml` tonight, so it stays recorded and untouched for the
  third stage running. One line whenever that lock lifts.
- **A caller workflow under some other filename still reads as drift** (review item 12).
  The fix offered was to search every `.github/workflows/*.yml` in every repo and read the
  matches — a call per file across forty repos, for a case that has never occurred, on the
  tool whose cost is already the thing being managed. The two filenames *are* the standard:
  `bin/enroll` writes one and this repo carries the other. The comment that claimed the
  code checked "ANY of its workflows" now says what the code actually does, and says why.
- **The review's second wording branch for a run-out date already in the past** — proved
  unreachable by the arithmetic above, so one branch ships rather than two, with the proof
  in the file so it does not get re-added.

### The verification run

Local CI first, run the way `ci.yml` runs it: `actionlint` clean, `shellcheck` clean over
all six scripts, `python3 -m py_compile bin/lib/*.py`, `check-templates.py`,
`check-classifier.sh`, `check-workflow-hygiene.sh` (20 assertions — every timeout
fixture through both parsers) and `check-audit.sh` (8 sections, 72 assertions).

Then a cheap end-to-end pass and one full audit, both against khglynn:

1. **`bin/audit --digest --skip-actions`, 07:44 CDT, 83 s, ~200 calls.** Ran before
   spending anything real, so a bash mistake would surface on a 200-call run rather than a
   1,600-call one. 129 words, the not-measured sentence intact, no repo reading `unknown`.
2. **One full `bin/audit --json`, 07:53–07:56 CDT, 3 min 21 s, about 1,400 calls** — run
   as `--json` so the digest and the table both render from a single spend. Waited seven
   minutes for the hourly reset first rather than starting it on 2,256 remaining, since
   the budget is shared with every other stage tonight; it started on 4,997 and ended on
   3,595. **40 repos: 5 enrolled, 29 security-only, 6 forks, 0 drifting, 0 unreadable.**

Its `--digest`, exactly as printed — **this is the full run, post-fix**:

```
*Dependency check — 14 Sep 2026*

5 of 40 repos keep themselves up to date. 12 updates waiting, the oldest 26 days old.
Build time this month: about 2453 of the free 3,000 private-repo minutes (an estimate). At this rate they run out around 16 Sep.

- ynai — 4 waiting, oldest 4 days.
- recordOS — 3 waiting, oldest 2 days.
- eachie — 2 waiting, oldest 26 days.
- ai-orchestrator — 1 waiting, oldest 2 days.
- okta-mcp-server — 1 waiting, oldest 2 days.
- and 1 more repo needs attention.

Also: 27 build jobs in 11 repos have no time limit; a hang costs six hours.
Also: 4 repos run their tests twice per change, which may be deliberate.
Note: eachie ran more builds than were measured, so the minutes read low.

To act: eachie's oldest update is 26 days old — merge or close it.
```

**149 words**, against the 150 the prompt and README promise, with the cap enforced rather
than hoped for. Private total **2,453 of 3,000**, run-out 16 Sep, `eachie` still capped at
300 of its 453 runs, 110 of Dependabot's own runs excluded across the account, and nothing
`partial` — every repo with billable builds had them read.

The 2,453 is not comparable to the resumed stage's 2,515 line for line: that number was a
full run's public rows plus a private-only re-measure taken four minutes later, and this
is the first single-pass figure with the Dependabot exclusion applied throughout. The
3,000-minute warning survives both, which is the part that matters.

### Still unverified after this stage

- **No figure here has been checked against a GitHub invoice.** Unchanged: the billing
  endpoints need a classic token with the `user` scope and are deliberately not called.
- **`eachie` is capped**, so its figure is low by whatever its 153 unmeasured runs cost.
- **The weekly routine has still never been created**, and no digest has ever been posted
  to Slack by it. Every one so far has been read in a terminal.
- **The new `unknown:` verdicts have not fired on live data** — no repo's settings or
  merge-rules workflow failed to read on either run today. They are pinned by the logic
  they replace, not by a live occurrence.
- **The larger-runner Dependabot exception** and the self-hosted case are both reasoned
  and tested, not observed: nothing in the account runs on either.

## 2026-09-14 07:00–08:15 CDT — the weekly digest routine is live, and the audit moves to Actions

- **07:01** "Dependabot weekly digest" created on kevn.hg@gmail.com through playwright-2 (`trig_01TTfxzWdWUA3J9PGPP6w6ap`): Opus 5, khglynn/repo-standards, Weekly → Monday (the form picks Monday itself) at 08:00, timezone taken from the browser and confirmed in words on the card, connectors Slack + "Github+" (the connector's name in that list), auto-fix off. Form notes folded into `routines/weekly-digest.md`.
- **07:01–07:04** First run by hand (session_0165TPv4zHci5xQ3HMpsRfTX). Finding: **the cloud sandbox has no `gh` binary at all** (`gh: command not found`, exit 127), so `bin/audit` can never run inside a routine; the connector's search endpoint tripped a secondary rate limit on the first calls while per-repo listing worked. The routine took its fallback correctly and posted an honest 84-word message at 07:02:56 ("The automatic check could not run this week…"), plus a phone push. It fires again on schedule at 08:00 today.
- **The fix, built after the workflow landed:** `.github/workflows/weekly-audit.yml` runs `bin/audit --digest` on GitHub's runners every Monday 12:15 UTC and commits the output as `latest-digest.md` on an orphan `audit-output` branch (outside the main ruleset, so a bot push is allowed); the routine's prompt now reads that file first (`git fetch --depth 1 origin audit-output && git show FETCH_HEAD:latest-digest.md`, then the connector as a second route), treats a file older than six days as missing, and only then falls back to per-repo list calls filtered to dependabot[bot] — never search. The job needs a read-only fine-grained PAT as the `AUDIT_READ_TOKEN` secret (Actions, Administration, Contents, Metadata, Pull requests — read, all repos); until Kevin mints it the job fails at its first step and says so, and the digest stays the fallback. The "no PAT" rule of 2026-09-11 was about a token that could merge; this one cannot change anything.
- **The shared workflow's own warning, fixed:** `dependabot-automerge.yml`'s `automerge` job now carries `timeout-minutes: 10` — the audit's very first finding was the one job that runs with write permission in every enrolled repo having no ceiling. The job makes a handful of API calls and waits on nothing.
- **The resumed workflow's result, for the record:** all nine MUST-FIXes and six NICEs from the Opus review applied (b814765 → db18e46), CI green on every commit, Sonnet verify clean. First single-pass digest: 149 words, private minutes **about 2,453 of the free 3,000, running out around 16 Sep** (an estimate; eachie capped at 300 of 453 runs so it reads low), 12 updates waiting, 27 jobs in 11 repos with no time limit, 4 repos running tests twice per change.
- Codex second opinion on this follow-up: started after the commit (trailing review; the job cannot run until the secret exists).
- **08:15 Codex on the follow-up (`cx-20260914-080434-78451-2639b8`): SHIP WITH CHANGES, one MUST.** The audit's output names private repos and their build usage, and `tee` plus `bin/audit`'s progress line would have printed it into this public repo's Actions log, then committed it to a public branch — a read-only token does nothing about what its results disclose. Fix applied 08:25: the job moved to a new private companion repo, `khglynn/repo-standards-audit` (private; one workflow that checks this repo out and runs `bin/audit --digest`, committing `latest-digest.md` to its own main; README there). `weekly-audit.yml` removed from here; the routine's repository switched to the private repo and its step 1 now reads the file from its own checkout. The two NICEs are in the private repo's workflow: `shell: bash` so a failing audit cannot hide behind a redirect, and the cost comment now says the token spends Kevin's shared 5,000-an-hour allowance rather than one of its own. Codex confirmed the rest: the orphan-branch mechanics (no longer used), the same-repo fetch from a scoped cloud credential, the six-day staleness test, the PAT permission list (nothing missing, nothing extra), and that ten minutes is ample for the automerge job.

## 2026-09-14 afternoon — the third enrolment shape: security-only, on an external build check

**Why.** `ynai` is private, Next.js on Vercel, has no CI workflow and no `dependabot.yml`, so
only GitHub's account-wide *security* pull requests reach it — and the only check on its PRs
is a Vercel commit status. Kevin's call this morning: those security bumps should merge when
the Vercel build is green. `bin/enroll` could not express that repo at all. `--ci-check` is
validated against workflow job ids (`pr-job-ids.py`), and there is no workflow to declare
`Vercel`; and enroll always wrote a `dependabot.yml` when it found none, which would have
switched routine version updates ON in a repo that deliberately has none. `bin/audit` would
then have called the result `drift: merge rules but no dependabot.yml`. About 29 of Kevin's
repos sit in that security-only state, several with a Vercel or Cloudflare build, so this is
a shape the standard should carry rather than a one-off.

**Verified first, before writing anything** (the numbers this work rests on):

- `khglynn/ynai` — private, not a fork, default branch `main`, `allow_auto_merge` **false**,
  one workflow (`.github/workflows/claude.yml`), no `dependabot.yml`, tree not truncated.
- The five most recent pull requests (#16, #11, #15, #9, #14 — two of them Dependabot's)
  **every one** carries a commit status with context exactly `Vercel`, state `success`.
  Each also carries a check-run named `Vercel Preview Comments` from the `vercel` app,
  which is a preview-comment bot and not a build signal — so the two really are distinct
  strings and the tool has to show both and let a person choose.
- The `Vercel` status's `creator` comes back `{login: null, type: null}`, so the app behind
  it cannot be named from that field. That is one of the reasons the ruleset pins no
  `integration_id`.

**What shipped.** Two flags on `bin/enroll`:

- `--security-only` — never writes `dependabot.yml`; says so in the PR body and again in the
  end-of-run summary, because a decision about what will *not* arrive is otherwise described
  only by omission. It refuses outright if the repo already has a `dependabot.yml`, since the
  summary's promise would be false.
- `--external-check <context>` — a required check no workflow declares. Validated against
  history, the only evidence that exists for it: the five most recent pull requests (any
  state — a repo whose Dependabot PRs all merged has no open ones to learn from), and for
  each head commit both `commits/{sha}/status` and `commits/{sha}/check-runs`. It refuses
  unless the context has really been reported on one of them, and names the PR that proved
  it. Mutually exclusive with `--ci-check`.

Two latent bugs fixed in passing, both of which the new flag would have walked into:

- The ecosystem scan is skipped entirely under `--security-only`. Its two `die`s both say
  "the dependabot.yml would be wrong" — about a file the run does not write — so an
  unreadable or truncated file list would have refused an enrolment that cannot depend on
  the answer.
- `--help` printed a hard-coded line range (`sed -n '2,20p'`) and truncated mid-sentence the
  moment this header grew. It prints the header comment block itself now, so it cannot drift.

### The two refusals, proved

```
$ bin/enroll khglynn/ynai --ci-check checks --external-check Vercel --dry-run
error: --ci-check and --external-check are mutually exclusive: the first is a job id from
       this repo's own workflows, the second a context some other service reports. Pick
       the one that will actually go green on a pull request here.
```

```
$ bin/enroll khglynn/ynai --security-only --external-check Vercell --dry-run
   …
   verifying 'Vercell' against this repo's five most recent pull requests…
   checks that HAVE been reported on those pull requests:
      Vercel                                       (commit status)
      Vercel Preview Comments                      (check run)
error: --external-check 'Vercell' is not one of them. A required check that
       nothing reports is a gate that can never go green — every Dependabot PR would
       queue for auto-merge and hang forever. Pick a name from the list above, exactly
       as it is spelled. Nothing on khglynn/ynai was changed.
```

One typo'd letter, and the tool prints the two real names rather than creating a gate that
can never go green. That is the same failure `--ci-check`'s validation was added to prevent,
reached through different evidence.

### The dry run the brief asked for, verbatim

**Not enrolled.** This was `--dry-run`; the real enrol is the lead's call after review.

```
$ bin/enroll khglynn/ynai --security-only --external-check Vercel --dry-run
DRY RUN — nothing below is actually written.
Enrolling khglynn/ynai
   --security-only: no dependabot.yml will be written, so this repo gets GitHub's
   account-wide SECURITY fixes and no routine version-update pull requests.
   default branch: main   visibility: private

── Labels
   would ensure label: dependencies
   would ensure label: major-review-needed
   would ensure label: dependabot-needs-human
   would ensure label: no-ci-gate
   would ensure label: dependabot-opted-out

── Ecosystems
   not checked — --security-only writes no dependabot.yml, so nothing is composed
   from the answer. Run without the flag to see what this repo would get.

── Files
   verifying 'Vercel' against this repo's five most recent pull requests…
   external check 'Vercel' has really been reported here ✓ — PR #16 (as a commit status)
   ⚠ it is reported by a third-party app, not by a file in this repo. If that
     integration is ever removed or stops building this repo's branches, the gate
     goes silent and update PRs will queue forever rather than fail loudly.
   dependabot.yml: NOT written (--security-only) — no version-update PRs will be
   opened here. GitHub's account-wide security fixes still arrive; they need no file.
   automerge stub: new
      ?? .github/workflows/dependabot-automerge.yml

   would open a pull request on branch 'standards/enroll' containing:
      ┄┄ new file: .github/workflows/dependabot-automerge.yml
      + # Dependabot auto-merge — this repo's copy is a POINTER, not a policy.
      + #
      + # The actual merge rules live in one place for all of Kevin's repos:
      + #   https://github.com/khglynn/repo-standards/blob/main/.github/workflows/dependabot-automerge.yml
      + # Fixing a bug there fixes every repo at once. Copied here 2026-09-11 by `bin/enroll`.
      + #
      + # Install path in the repo being enrolled: .github/workflows/dependabot-automerge.yml
      + #
      + # Why `pull_request_target` and not `pull_request`: Dependabot's PRs run with a read-only
      + # token and no access to secrets, so a `pull_request` workflow could not approve or merge
      + # anything. `pull_request_target` runs in the BASE repo's context with write permission.
      + # That is only safe because the called workflow never checks out the pull request's code —
      + # do not add a checkout step to either file.
      + 
      + name: dependabot-automerge
      + 
      + on:
      +   pull_request_target:
      +     types: [opened, synchronize, reopened, ready_for_review]
      + 
      + permissions:
      +   contents: write        # enable auto-merge, refresh a stale branch
      +   pull-requests: write   # approve, label, comment
      +   issues: write          # create the labels (labels are an Issues-API object)
      + 
      + jobs:
      +   automerge:
      +     uses: khglynn/repo-standards/.github/workflows/dependabot-automerge.yml@main
      +     # ------------------------------------------------------------------------------
      +     # THE EXCEPTION POINTS. Delete the `with:` block entirely to take every default.
      +     # Uncomment only the line you actually want to differ in THIS repo, and say why.
      +     #
      +     # Anything you write here is SAFE from `bin/enroll`: once this file points at
      +     # repo-standards, re-running enroll leaves it untouched rather than re-stamping the
      +     # template over your exception (fixed 2026-09-11 — it used to silently revert it).
      +     # ------------------------------------------------------------------------------
      +     # with:
      +     #   merge-patch: true              # x.y.Z bumps merge themselves. Default true.
      +     #   merge-minor: false             # x.Y.z bumps wait for a human. Use in a repo where a minor has bitten you.
      +     #   merge-method: merge            # squash (default) | merge | rebase
      +     #   require-ci: true               # never auto-merge on a branch with no required check. Leave true.
      +     #   stale-strategy: comment        # none (default) | comment — what to do with a PR that is behind main AND red
      +     #   label-major: major-review-needed
      +     #   label-unparsed: dependabot-needs-human
      +     #   label-no-ci: no-ci-gate
      +     #   label-opted-out: dependabot-opted-out

── Repo setting: allow auto-merge
   would turn it on (gh api -X PATCH repos/khglynn/ynai -F allow_auto_merge=true)

── Repo setting: Actions may approve pull requests
   would turn it on (gh api -X PUT repos/khglynn/ynai/actions/permissions/workflow -F can_approve_pull_request_reviews=true)

── CI gate (ruleset 'standards-ci')
   would CREATE ruleset 'standards-ci'
   requiring check 'Vercel' on main, repository admins bypass always

════════════════════════════════════════════════════════════════════
 khglynn/ynai — dry run — nothing changed
════════════════════════════════════════════════════════════════════
 Ecosystems found: not checked (--security-only writes no dependabot.yml)
 Files proposed: .github/workflows/dependabot-automerge.yml
 Pull request: (dry run — not opened)
 CI gate: 'Vercel' required on main — reported by another
          service, not by a workflow in this repo (you can still push directly)

 SECURITY FIXES ONLY. No dependabot.yml was written, so Dependabot will open no
 routine version-update pull requests here. GitHub's account-wide security fixes
 still arrive, and those are what will approve and merge themselves once
 'Vercel' is green. Nothing else merges by itself.

 YOUR MOVE: nothing — this was a dry run. Re-run without --dry-run to do it.
```

### The audit: a stub with no dependabot.yml is a shape, not a fault

`bin/audit` called that combination `drift: merge rules but no dependabot.yml, so no update
PRs` — which would have nagged about every repo this new shape is for. It now reads
**`enrolled (security fixes only)`** when the rest of the machinery is really there: the
same three settings the full `enrolled` verdict demands (auto-merge on, a required check,
the approve switch), in the same order and the same words. A stub with no required check is
still drift, and it gets the *missing-gate* message the full path already uses. The old
no-dependabot.yml wording is retired: that file is the intended half now, and naming it
would send Kevin to fix the thing that is not broken.

**Counting.** It counts as ENROLLED, with the parenthetical said out loud in both the table
summary and the digest headline — `2 of 3 repos keep themselves up to date (1 for security
fixes only)`. Filing it under `security-only` would put a repo whose security fixes merge
themselves in the same bucket as one where nothing merges at all, which is the more
misleading of the two errors. Counting it silently would let "keeps itself up to date" mean
two different things in the one sentence Kevin reads every Monday. The headline is never
trimmed by the 150-word cap — only the repo list gives way — so those five words cannot
vanish on a busy week. Measured: the three-row fixture digest is 80 words.

**The rule moved, and that is the bigger change.** The status chain lived inline in
`bin/audit`'s repo loop, where the only way to exercise it was forty GitHub calls — so the
column `bin/audit` itself calls "the whole point of this tool" had no test at all, while the
two jq predicates above it had four each. Every bug this repo has caught in itself has been
a confident answer nobody could test. Adding a ninth branch to an untested chain would have
been that bet a fourth time. It is `bin/lib/verdict.sh` now: a pure function of eight
strings, sourced by `bin/audit` and by the self-check.

### Fixture results

`bin/lib/check-audit.sh` gained two sections: **72 assertions before, 108 after**, all
green (counted by running both, not estimated — the first draft of this line said 82).

- **Section 9 — the status word itself.** Every pre-existing branch pinned by name (that is
  what proves the extraction was verbatim), then the new shape from eight angles: enrolled
  with an external check, with a multi-context check, with no app manifest, with the approve
  switch unread (`--skip-actions` leaves it `?`, and that must not demote a good repo —
  the same absent-versus-false trap `APPROVE_JQ` pins one level down); and drift when the
  gate, the auto-merge switch, or the approve switch is missing.
- **…and an exhaustive sweep.** All 1,440 combinations of the eight inputs, asserting the
  rule's entire output alphabet: 14 status words and no others. That is what makes the
  retired wording *unreachable* rather than merely unused, and it catches a future typo that
  the renderer would otherwise swallow — it switches on `startswith`, so an unrecognised
  verdict is not an error, it is silently counted as drift.
- **Section 10 — all three renderings.** Table summary and row, `--json` (`summary.enrolled`
  2, `summary.enrolled_security_only` 1, `summary.security_only` 0, `summary.drifting` 1),
  digest headline, the drifting repo's own line, the word cap — and a control proving the
  parenthetical is absent when no repo earns it.

**Mutation-tested**, because an assertion that cannot fail is not one. Renaming the status
in `verdict.sh` to `enrolled (security only)` turned four named cases red and produced a
one-line alphabet diff; restoring it went green again.

**Ran for real** (`bin/audit --skip-actions`, ~200 calls, 85 seconds): 41 active repos —
5 enrolled, 30 security-only, 6 forks, **0 drifting**. Every status word on all 41 real
repos is inside the pinned 14-word alphabet. `ynai` reads `security-only` today with four
open Dependabot pull requests, the oldest four days old; after the real enrol it becomes
`enrolled (security fixes only)` and those four start merging behind the Vercel build.
(Thirty security-only repos, against the brief's estimate of 29.)

CI's shellcheck gains `-x` so it follows the `source` directive instead of filing the one
file that decides every status word under "not specified as input".

### The shared workflow's gate: a context is a context (read, not edited)

The brief asked for this to be confirmed before anything relied on it. **It passes, and no
edit is needed** — neither to `.github/workflows/dependabot-automerge.yml` nor to
`templates/caller-stub.yml`.

The `gate` step reads the base branch's required checks two ways and never asks where they
come from:

- rulesets — `[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context]`
  takes `.context` and ignores anything beside it, `integration_id` included;
- classic protection — `(.required_status_checks.checks | map(.context)) + (.contexts)`;
- then `if [ -n "$checks" ] || [ "$IN_REQUIRE_CI" = "false" ]; then ok=true`.

Nothing resolves a context to a workflow, a job, or an app. Every later step keys off
`steps.gate.outputs.ok`, and the only other consumer, `required-checks`, is used twice: once
in a log line, and once in the advisory stale-and-red step — whose jq already reads
`(.name // .context // "")` and `(.conclusion // .state // "")`, i.e. it was written to
handle commit statuses alongside check-runs. So an external status context is handled
correctly there too, not merely ignored.

Confidence: **high** for this repo's own code, which was read end to end. The remaining link
is GitHub's, not ours — that a ruleset requiring the context `Vercel` is satisfied by a
commit status whose context is `Vercel`. That is the same mechanism a job id relies on (a
required check is one free-text namespace fed by both the statuses and the check-runs APIs),
and it is what `bin/audit` has always assumed when it reads contexts out of a ruleset. It
cannot be proved from here without creating the ruleset, which is the real enrol — so the
first live security PR on `ynai` is the confirmation, and worth a look.

### The independent review, and the eight things it found

Codex reviewed the diff adversarially before any of this could be relied on (run
`cx-20260914-154949`, 280s, verdict **SHIP WITH CHANGES**). Two findings were the exact
failure this toolkit exists to prevent — a confident answer nobody had verified — and one of
them had just been shipped by the session writing it.

**P1 — the evidence was the wrong evidence.** A context reported on a *human* pull request
proves nothing about Dependabot's. A workflow scoped to `feature/**`, or a Vercel project set
to skip bot branches, would pass a plain name match and then never report on the branches
that matter — producing precisely the gate-that-never-goes-green the flag was written to
prevent. The author of every sampled pull request is read now, and three cases are kept
apart: proved on a Dependabot PR (the real thing); proved only on human PRs with no
Dependabot PR in the sample to judge by (accepted, with a line saying so out loud); and
proved on human PRs while Dependabot's own went ungated — **refused**, because that is
positive evidence of the bad case rather than an absence of evidence. `ynai` turns out to be
the first case: `Vercel` is reported on PR #15, Dependabot's own.

**P1 — an empty `$REQUIRED_CHECK` meant "this run named no check", never "this branch has
none"** — but the summary and the PR body said the second. A repo carrying an existing
ruleset would have been told every security fix waits for a human while they merged
themselves. The branch's effective rules are read now (rulesets, classic as fallback) into a
four-state `GATE_STATE` — `new` / `preexisting` / `none` / `unknown` — and both the body and
the summary speak only from that, including saying "unknown" when neither endpoint answered.

**Six P2s, each a real defect:**

1. `grep -qxF "$CTX"` with no `--`: `--external-check -eVercel` **matched** a history
   containing only `Vercel` (reproduced), and the ruleset would then have required the
   literal string `-eVercel`, which nothing reports. Fixed here *and* in the `--ci-check`
   path, which carried the same bug plus a SIGPIPE hazard — `printf | cut | grep -q` under
   `pipefail` can report 141 on a successful match, rejecting a **valid** job id, and only
   once the job list outgrows a pipe buffer. Both use here-strings now. A multi-line context
   is refused outright, since `grep -F` reads each line as a separate alternative.
2. Neither history endpoint paginated; both default to 30 results. Declaring a context absent
   from a truncated read is this repo's cardinal sin one level down. `--paginate` on both.
3. An unreadable PR head was counted as a head with no checks — **and the obvious probe does
   not work.** `commits/{sha}/status` answers **200** with `{"state":"pending","statuses":
   [],"total_count":0}` for a commit that does not exist in the repo at all (measured against
   `khglynn/ynai` with an all-zeroes SHA). Its exit status can never tell "no statuses" from
   "no such commit". `commits/{sha}/check-runs` **does** 404 on the same SHA and returns an
   empty array for a real commit with none, so it is the honest reachability probe — and it
   is a call the loop already makes. A head it cannot reach is now reported, not inferred
   from. Proved end to end by injecting two unreachable heads into a throwaway copy:
   `note: 5 of 7 pull-request heads could be read; no answer for #999 #998`.
4. Re-running `enroll` over an already-open enrol pull request replaced the branch and left
   the old description standing — so a repo re-run with `--security-only` carried a PR still
   promising weekly version updates. That promise is the *only* place the decision is
   visible, because what it describes is a file's absence. The body is generated for both
   paths now.
5. Every refusal said "nothing on $TARGET was changed" after five `gh label create --force`
   calls had already run. Validation moved ahead of the labels step, so the sentence is true.
6. The 1,440-case sweep asserted the **set** of status words, and `sort -u` divorces the
   answers from the inputs. Codex swapped the fork branch with the unreadable-stub branch and
   the whole suite stayed green, although a fork with an unreadable stub had started reading
   `unknown`. The full input → output mapping is a checked-in fixture now
   (`bin/lib/fixtures/audit/verdict-matrix.txt`, regenerated by `bin/lib/verdict-matrix.sh`),
   plus five named cases for the overlaps where the chain's ORDER is the only thing deciding.
   Mutation-tested against Codex's exact swap: the matrix and the new named case both go red.

**And two bugs in the new guards themselves**, caught by running them rather than trusting
them. `case "$x" in *"$(printf '\n')"*)` is `**`, because command substitution strips
trailing newlines — so the newline guard rejected every input including the empty string,
and its own test showed it. And the matrix fixture's two header lines end in `-> status`,
which had the alphabet assertion reading "15 distinct status words" and "1,441
combinations". Both fixed; both are now the reason a comment exists at those lines.

Codex confirmed the parts that were right: all 1,440 combinations matched the original rule
except the intended branch, no path installs a `dependabot.yml` under `--security-only`,
nothing downstream of the skipped ecosystem step broke, and the digest parenthetical is never
lost. Final state: **117 assertions, all green**, and the whole CI suite run locally
(actionlint, templates, `shellcheck -x`, `py_compile`, classifier, workflow hygiene, audit
self-checks, ecosystem detector).

### The dry run, re-run after every fix

**Still not enrolled.** The real enrol is the lead's call after review. Note the evidence
line: it now names a Dependabot pull request, and validation happens before a single label
is touched.

```
$ bin/enroll khglynn/ynai --security-only --external-check Vercel --dry-run
DRY RUN — nothing below is actually written.
Enrolling khglynn/ynai
   --security-only: no dependabot.yml will be written, so this repo gets GitHub's
   account-wide SECURITY fixes and no routine version-update pull requests.
   default branch: main   visibility: private

── Checks
   verifying 'Vercel' against this repo's five most recent pull requests…
   external check 'Vercel' reports on Dependabot's own pull requests ✓ — PR #15 by dependabot[bot] (as a commit status)
   ⚠ it is reported by a third-party app, not by a file in this repo. If that
     integration is ever removed or stops building this repo's branches, the gate
     goes silent and update PRs will queue forever rather than fail loudly.

── Labels
   would ensure label: dependencies
   would ensure label: major-review-needed
   would ensure label: dependabot-needs-human
   would ensure label: no-ci-gate
   would ensure label: dependabot-opted-out

── Ecosystems
   not checked — --security-only writes no dependabot.yml, so nothing is composed
   from the answer. Run without the flag to see what this repo would get.

── Files
   dependabot.yml: NOT written (--security-only) — no version-update PRs will be
   opened here. GitHub's account-wide security fixes still arrive; they need no file.
   automerge stub: new
      ?? .github/workflows/dependabot-automerge.yml

   would open a pull request on branch 'standards/enroll' containing:
      ┄┄ new file: .github/workflows/dependabot-automerge.yml
      [templates/caller-stub.yml verbatim — elided here]

── Repo setting: allow auto-merge
   would turn it on (gh api -X PATCH repos/khglynn/ynai -F allow_auto_merge=true)

── Repo setting: Actions may approve pull requests
   would turn it on (gh api -X PUT repos/khglynn/ynai/actions/permissions/workflow -F can_approve_pull_request_reviews=true)

── CI gate (ruleset 'standards-ci')
   would CREATE ruleset 'standards-ci'
   requiring check 'Vercel' on main, repository admins bypass always

════════════════════════════════════════════════════════════════════
 khglynn/ynai — dry run — nothing changed
════════════════════════════════════════════════════════════════════
 Ecosystems found: not checked (--security-only writes no dependabot.yml)
 Files proposed: .github/workflows/dependabot-automerge.yml
 Pull request: (dry run — not opened)
 CI gate: 'Vercel' required on main — reported by another service,
          not by a workflow here (you can still push directly)

 SECURITY FIXES ONLY. No dependabot.yml was written, so Dependabot will open no
 routine version-update pull requests here. GitHub's account-wide security fixes
 still arrive, and those are what will approve and merge themselves once
 'Vercel' is green. Nothing else merges by itself.

 YOUR MOVE: nothing — this was a dry run. Re-run without --dry-run to do it.
```

### Round two: five more findings, and the same ordering bug twice in one afternoon

The fixes were sent back to Codex (`cx-20260914-160440`, verdict SHIP WITH CHANGES again).
Three of its five findings had already been caught while it ran; two were new. All five, and
what each would have cost:

1. **Two surfaces, one answer.** `GATE_STATE=none` was still reachable when only ONE of the
   two places a required check can live had actually answered — rulesets empty while classic
   protection failed, or the mirror image — and a swallowed `jq` failure did the same while
   claiming the read had succeeded. Each surface is `present` / `absent` / `unknown` on its
   own evidence now, and `none` needs **both** to say absent. The classic read separates 403
   from 404 again (`gh api -i`) — **a bug this repo fixed once already**, in the shared
   workflow on 2026-09-11, and which this session quietly reintroduced. That single fact is
   the argument for having asked for a second review at all.
2. **The ruleset read was itself unpaginated**, in `bin/enroll` and `bin/audit` both: 30
   rules by default, so a required check on page two reads as no check at all. In enroll that
   is a false "nothing merges here"; in audit it is a drift verdict about a repo that is
   fine. `--paginate` on both.
3. **A newer contradiction now outranks an older match.** The loop took the first Dependabot
   hit and stopped, so a Vercel project that stopped building bot branches last week would
   still have enrolled cleanly on month-old evidence. The newest *readable* Dependabot pull
   request is what speaks to today.
4. **An unreadable Dependabot head is not an ungated one.** `bot_seen` counted pull requests
   before either history read succeeded, so a failed read produced the categorical "it does
   not run on Dependabot's branches" refusal — contradicting the "nothing was inferred from
   those" note printed three lines above it.
5. **A failed PR lookup is not "there is no PR."** The branch is already pushed by then, so
   swallowing the failure sent the run down the create path; creation fails because the PR
   does exist, and its old description survives a branch that changed shape underneath it.

**And then the same ordering bug, twice in one afternoon.** Fixing (3) put a `bot_proof`
branch at the top of the evidence chain, which shadowed every recency branch below it — so
the refusal never fired. A *simulated run* caught it; reading the code had not, twice. That
is the second inline if/elif chain in this repo to go wrong by ordering in a single session,
so it got the same treatment as the first: `bin/lib/check-evidence.sh`, a pure function of
six values printing one verdict token, with all 216 input combinations pinned in
`bin/lib/fixtures/audit/evidence-matrix.txt` and one invariant stated in words — *a readable
Dependabot pull request missing the check can only ever end in refusal or a deliberate
`ALLOW_UNPROVEN_CHECK=1`, never a quiet yes.*

The method that actually found things, worth keeping: **every refusal path was exercised by
injecting the failure into a throwaway copy of `bin/enroll`** (two unreachable PR heads; a
check blanked on bot PRs; a check blanked on the newest bot PR only), run for real against
`ynai`, then deleted. Three of the bugs above survived careful reading and died in under a
minute to a simulated run.

Final state: **128 assertions, 0 failures**, full CI suite green locally, two golden
matrices (1,440 verdict rows, 216 evidence rows) pinned as fixtures.

### One thing found and NOT fixed, because the brief forbids the file

`.github/workflows/dependabot-automerge.yml:303` reads the base branch's rulesets
**unpaginated** — `gh api "repos/$REPO/rules/branches/$base_esc"`, the same 30-rule default
that was just fixed in `bin/enroll` and `bin/audit`. On a branch with more than 30 rules the
gate would see no required check.

**It fails in the safe direction**, which is why this is a note and not an alarm: an empty
`checks` with the default `require-ci: true` sets `ok=false`, so the PR gets a `no-ci-gate`
label and does **not** merge. Nothing merges untested; a PR would just wait for a human, with
a comment that misdescribes why. None of Kevin's repos is near 30 rules today. The fix is one
word (`--paginate`) plus `?per_page=100`, whenever that file is next touched.

### The dry run, final

**Still not enrolled** — the real enrol is the lead's call. Note the first evidence line: the
check is now proven on Dependabot's *own* newest pull request, not merely on some pull
request, and every check happens before a single label is created.

```
$ bin/enroll khglynn/ynai --security-only --external-check Vercel --dry-run
DRY RUN — nothing below is actually written.
Enrolling khglynn/ynai
   --security-only: no dependabot.yml will be written, so this repo gets GitHub's
   account-wide SECURITY fixes and no routine version-update pull requests.
   default branch: main   visibility: private

── Checks
   verifying 'Vercel' against this repo's five most recent pull requests…
   external check 'Vercel' reports on Dependabot's own pull requests ✓ — PR #15 by dependabot[bot] (as a commit status)
   ⚠ it is reported by a third-party app, not by a file in this repo. If that
     integration is ever removed or stops building this repo's branches, the gate
     goes silent and update PRs will queue forever rather than fail loudly.

── Labels
   would ensure label: dependencies
   would ensure label: major-review-needed
   would ensure label: dependabot-needs-human
   would ensure label: no-ci-gate
   would ensure label: dependabot-opted-out

── Ecosystems
   not checked — --security-only writes no dependabot.yml, so nothing is composed
   from the answer. Run without the flag to see what this repo would get.

── Files
   dependabot.yml: NOT written (--security-only) — no version-update PRs will be
   opened here. GitHub's account-wide security fixes still arrive; they need no file.
   automerge stub: new
      ?? .github/workflows/dependabot-automerge.yml

   would open a pull request on branch 'standards/enroll' containing:
      ┄┄ new file: .github/workflows/dependabot-automerge.yml
      [templates/caller-stub.yml verbatim — elided here]

── Repo setting: allow auto-merge
   would turn it on (gh api -X PATCH repos/khglynn/ynai -F allow_auto_merge=true)

── Repo setting: Actions may approve pull requests
   would turn it on (gh api -X PUT repos/khglynn/ynai/actions/permissions/workflow -F can_approve_pull_request_reviews=true)

── CI gate (ruleset 'standards-ci')
   would CREATE ruleset 'standards-ci'
   requiring check 'Vercel' on main, repository admins bypass always

════════════════════════════════════════════════════════════════════
 khglynn/ynai — dry run — nothing changed
════════════════════════════════════════════════════════════════════
 Ecosystems found: not checked (--security-only writes no dependabot.yml)
 Files proposed: .github/workflows/dependabot-automerge.yml
 Pull request: (dry run — not opened)
 CI gate: 'Vercel' required on main — reported by another service,
          not by a workflow here (you can still push directly)

 SECURITY FIXES ONLY. No dependabot.yml was written, so Dependabot will open no
 routine version-update pull requests here. GitHub's account-wide security fixes
 still arrive, and those are what will approve and merge themselves once
 'Vercel' is green. Nothing else merges by itself.

 YOUR MOVE: nothing — this was a dry run. Re-run without --dry-run to do it.
```

### Round three: the bug I wrote one commit earlier

A third pass (`cx-20260914-161931`) on the newest and least-reviewed code only. Four
findings, and the first is the one that matters — it was mine, from the commit that had just
fixed the pagination gap.

**An HTTP error became a required status check.** On a real error `gh api --jq` cannot apply
its filter, so it writes the **raw error body to stdout** and exits 1 — measured:
`{"message":"Not Found","documentation_url":…,"status":"404"}`, all on one line. `bin/audit`
piped that straight into the new raw-text join, which turned it into a context; a context is
non-empty; non-empty skipped the classic-protection fallback — and a repo with **no gate at
all** read `enrolled`. The previous jq-over-JSON form was accidentally immune, because that
filter simply yielded nothing on an error body; the faster paginated form is not. The result
is used only when gh reports success now, which is what `bin/enroll` already did.

That one is worth sitting with. It was introduced *by a fix*, in a commit whose entire
subject was truncation safety, and it turned the audit's most load-bearing column into a
confident lie in exactly the direction that hides work — a repo with nothing protecting it
reading as enrolled. Two rounds of review had already passed over this file.

**A partial read became evidence of absence.** A Dependabot pull request counted as "read"
the moment its check-runs call succeeded, so one whose STATUS list failed and whose
check-runs carried nothing was recorded as "does not have the check" — and that alone
refuses an enrolment. A hit is conclusive on its own, since positive evidence needs only the
surface it appeared on; concluding ABSENCE needs both surfaces read, because the check may
live on the one that failed.

**The invariant assertion was half blind.** `bot_proof` was printed into the evidence matrix
as its literal value — `PR #14`, two whitespace fields — so awk's columns shifted and "a
readable bot PR missing the check never yields a quiet acceptance" only ever examined the
empty-proof rows. Flipping every proven-bot refusal in the fixture left it passing. It prints
`set` / `none` now, and that mutation goes red.

**The fixture was not a superset of reachable inputs.** enroll samples five pull requests, so
its counters reach 5 while the matrix stopped at 2, and `allow` only tried `1` and empty — so
a regression affecting `bot_missing > 1`, or one that started treating `"true"` as an
override, would have passed the pinned matrix unchanged. 216 rows → **1,152**, with
near-miss override values included because the rule wants exactly `"1"`.

**And the counting mistake, twice.** A commit message said "82 assertions" when it was 72,
and a later one said 135 when it was 131 — both guesses, in a repo whose entire argument is
that a number nobody can check is worse than no number. The suite prints its own total now
(`check-audit: 131 assertions, 0 failures.`), counted where the assertions are emitted rather
than kept in step by hand. The round-three commit message still carries the wrong 135; it is
pushed, and rewriting published history to fix a count is a worse trade than this note.

**Method that kept working:** every one of these was reproduced before it was fixed — a stub
`gh` that emits an error body and exits 1, the failure injected into a throwaway copy of
`enroll`, the fixture mutated to check the checker. Three rounds of review found 17 real
defects across roughly 500 lines. None of them was found by reading alone.

### Final state

- **131 assertions, 0 failures**; full CI suite green locally and on GitHub.
- Two pure functions extracted from inline if/elif chains that had each gone wrong by
  ordering: `bin/lib/verdict.sh` (the audit's status word) and `bin/lib/check-evidence.sh`
  (what the `--external-check` history proved), with **1,440** and **1,152** input
  combinations pinned as checked-in fixtures.
- `ynai` is ready to enrol and **has not been enrolled** — that is the lead's call.

```
$ bin/enroll khglynn/ynai --security-only --external-check Vercel --dry-run
DRY RUN — nothing below is actually written.
Enrolling khglynn/ynai
   --security-only: no dependabot.yml will be written, so this repo gets GitHub's
   account-wide SECURITY fixes and no routine version-update pull requests.
   default branch: main   visibility: private

── Checks
   verifying 'Vercel' against this repo's five most recent pull requests…
   external check 'Vercel' reports on Dependabot's own pull requests ✓ — PR #15 by dependabot[bot] (as a commit status)
   ⚠ it is reported by a third-party app, not by a file in this repo. If that
     integration is ever removed or stops building this repo's branches, the gate
     goes silent and update PRs will queue forever rather than fail loudly.

── Labels
   would ensure label: dependencies
   would ensure label: major-review-needed
   would ensure label: dependabot-needs-human
   would ensure label: no-ci-gate
   would ensure label: dependabot-opted-out

── Ecosystems
   not checked — --security-only writes no dependabot.yml, so nothing is composed
   from the answer. Run without the flag to see what this repo would get.

── Files
   dependabot.yml: NOT written (--security-only) — no version-update PRs will be
   opened here. GitHub's account-wide security fixes still arrive; they need no file.
   automerge stub: new
      ?? .github/workflows/dependabot-automerge.yml

   would open a pull request on branch 'standards/enroll' containing:
      ┄┄ new file: .github/workflows/dependabot-automerge.yml
      [templates/caller-stub.yml verbatim — elided here]

── Repo setting: allow auto-merge
   would turn it on (gh api -X PATCH repos/khglynn/ynai -F allow_auto_merge=true)

── Repo setting: Actions may approve pull requests
   would turn it on (gh api -X PUT repos/khglynn/ynai/actions/permissions/workflow -F can_approve_pull_request_reviews=true)

── CI gate (ruleset 'standards-ci')
   would CREATE ruleset 'standards-ci'
   requiring check 'Vercel' on main, repository admins bypass always

════════════════════════════════════════════════════════════════════
 khglynn/ynai — dry run — nothing changed
════════════════════════════════════════════════════════════════════
 Ecosystems found: not checked (--security-only writes no dependabot.yml)
 Files proposed: .github/workflows/dependabot-automerge.yml
 Pull request: (dry run — not opened)
 CI gate: 'Vercel' required on main — reported by another service,
          not by a workflow here (you can still push directly)

 SECURITY FIXES ONLY. No dependabot.yml was written, so Dependabot will open no
 routine version-update pull requests here. GitHub's account-wide security fixes
 still arrive, and those are what will approve and merge themselves once
 'Vercel' is green. Nothing else merges by itself.

 YOUR MOVE: nothing — this was a dry run. Re-run without --dry-run to do it.
```

## 2026-09-14 17:19 CDT — ynai enrolled; the first live run of the new approve step failed on a gh flag

- Kevin ran `bin/enroll khglynn/ynai --security-only --external-check Vercel` (the new mode, built and reviewed this afternoon) and merged the pointer PR (#17). Four `@dependabot recreate` nudges followed. The two majors (#18 nodemailer 9 → 10, #19 deepmerge-ts 7 → 8) were labelled `major-review-needed` correctly; a new "Dependabot verdict · ynai" routine (`trig_01S8V7kddMxPZbyLrDWgEBk3`, same prompt and filters as the other four) now exists to speak for them.
- The two minors (#13, #14) reached the approve step and **failed**: `gh api --paginate --slurp … --jq` is rejected by gh ("the --slurp option is not supported with --jq or --template"). That was Codex's fix #3 from this morning, applied as suggested and never exercised live until now — every earlier merge predated it. The step failed loudly and labelled both PRs `dependabot-needs-human`, which is the designed failure. Fix: pipe to a separate `jq`, with an unreadable review list counting as zero (the only cost is a possible duplicate approval). Reproduced and proved locally against ynai #14 before pushing. The paginated ruleset read added at 80c2dbc already used the piped form and is fine.
- Lesson for the log: a reviewer's exact command is a claim like any other; a flag combination has to be run once before it ships in a workflow that every repo calls.

## 2026-09-14 18:19–18:40 CDT — the weekly audit runs for real; the read-only token could not see one setting

- Kevin minted the read-only fine-grained PAT (Actions, Administration, Contents, Metadata, Pull requests; all repos; expires 2027-09-14) and it is the `AUDIT_READ_TOKEN` secret on khglynn/repo-standards-audit. First run 18:19: green end to end, digest committed. But it read "1 of 41 repos keep themselves up to date; 5 are half set up" against this morning's 5 enrolled, and told Kevin to finish setting up ynai, which was finished at 17:22.
- Cause, proven by probing each endpoint with that token against ynai: the REST repository object **omits `allow_auto_merge`** for a caller without push access (a read-only token has none), so `bin/audit` read an empty string and reported "auto-merge is off" for every enrolled repo. Every other call it makes (rulesets, the approve switch, contents, trees, runs) works with the token. GraphQL's `autoMergeAllowed` answers the same question for a read-only caller; `bin/audit` now asks that (8098d4e) and maps anything but true/false to "?" (unknown, said so). Second run dispatched 18:36.
- Also today: the watcher in khglynn/google_workspace_mcp posts to #infra-ops (new Errors Bot webhook; the old one deleted; #misc-build-errors archived), and says a notice once then weekly (#18) using the workflow token for its memory (#19, after the fleet PAT was refused on the variables API).
