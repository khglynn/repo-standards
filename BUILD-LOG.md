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

**`repo-standards` CI: green on both pushes to main.** `checks` = actionlint (+shellcheck
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
| #116 | ai 4.3.19 → 5.0.52 | **unknown** → `dependabot-needs-human` |
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
