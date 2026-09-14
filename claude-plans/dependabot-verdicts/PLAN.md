# Dependabot verdicts arc — plan and acceptance

**Written:** 2026-09-14 00:20 CT. **Spec origin:** Kevin, 2026-09-10 → 09-13 (hg-agents `claude-plans/2026-09-10-slack-agent-landscape.md`).

## Done-done-done acceptance
1. Security half on for every repo Kevin owns, auto-on for new ones. ✅ 2026-09-11 (account switch; verified per repo).
2. Every repo with a dependency manifest and a push in the last six months is enrolled: stub → shared workflow, `dependabot.yml`, auto-merge on, a required CI check, the approve switch on. ✅ eachie, festival-navigator, kevinhg-com, list-maker. ⏳ remaining candidates: ynai (live product, Vercel-only checks → digest-only by Kevin's default), remembrall, harness-atlas, hevy-mcp, recordOS, spotify-bulk-actions-mcp, okta-mcp-server, wkt, sync-bot, notion-souped-up-mcp, lunch-no-drop, trimmedia.github.io, hgbot, starter, ai-orchestrator, AIOpsSurvey — each needs a CI job name or gets security-only.
3. Patch and minor bumps merge themselves once CI is green; majors and unparseable bumps get a label and never merge alone. ✅ proven live in eachie (major labelled) and list-maker + kevinhg-com (patch merged).
4. Every labelled PR produces one plain-English verdict in #dependabot within minutes, in the seven-line shape, ending with the exact reply to send. ✅ proven in the final shape on eachie #161 (2026-09-14 02:33); five routines (eachie, festival-navigator, kevinhg-com, list-maker, ynai).
5. A weekly digest in #dependabot: open Dependabot PRs by repo with age and label, plus drift (repo missing stub / auto-merge / required check / approve switch; a job without timeout-minutes; the Actions-minutes estimate). ✅ built 2026-09-14; the audit runs weekly in the private repo khglynn/repo-standards-audit on a read-only token and the routine posts its file; first correct digest 18:40. ⏳ first scheduled post: Monday 2026-09-21 08:00 CT.
6. Nothing in the standard needs Kevin's Mac to be on. ✅ (Actions + Anthropic cloud).
7. Cost stays inside the free Actions pool most months; the $48 budget is the backstop. ✅ set; the digest reports the burn (2,346 of 3,000 on 14 Sep, out around 17 Sep — September will dip into the budget).
8. Kevin's channel tidy (#infra-ops, #eachie-digest, archive the dead ones). ✅ 2026-09-14 afternoon, through Kevin's Chrome.

## Sequence for the overnight run (2026-09-14)
A. State banked (this folder) → B. `bin/audit` improvements per repo-standards#1, via a Workflow (Opus builder → Opus reviewer → fixer → Sonnet verify), committed to main → C. Codex second opinion on tonight's workflow change (approve step) → D. the weekly digest routine on Kevin's personal claude.ai, run once by hand, output tuned → E. list-maker `cloudflare-trigger/` Dependabot coverage as a PR → F. morning report in NOW.md + hg-agents memo + Notion session save.

## Out of scope tonight (needs Kevin)
Enrolling more repos (each needs a CI job name he agrees to gate on); channel renames; republishing the artifact page (owning login); anything that merges into a product repo.
