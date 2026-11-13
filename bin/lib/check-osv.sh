#!/usr/bin/env bash
# Prove the shared workflow's OSV step (step 4b, added 2026-11-12) still decides what we
# think it decides. CI runs it with --live.
#
# The step's two rules have to sit inline in the workflow (it never checks out code, so it
# cannot read a .jq file), so this pulls them out of the workflow and runs them on fixtures:
#   OSV_FILES_JQ  which changed files are lockfiles to scan, and where each one's base copy is
#   OSV_NEW_JQ    which advisories the PR ADDS, the only ones that stop a merge
# It also checks the wiring: nothing merges unless the scan said clear, and the scanner
# runs with an empty environment and with call analysis off.
#
# --live downloads the pinned OSV-Scanner and checks it against the pinned checksum, so a
# typo in the pin fails this repo's CI instead of every enrolled repo at once. On Linux
# x86_64 it then runs the scanner, with the workflow's flags, on lockfiles written at run
# time: clean, vulnerable, malicious, broken. They are written here and never committed,
# because a committed lockfile naming a malicious package would have Dependabot raising
# alerts against this repo's own fixtures. The live part needs github.com and api.osv.dev.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$HERE"
WF=.github/workflows/dependabot-automerge.yml
FX=bin/lib/fixtures/osv
fail=0
ok()   { echo "ok: $1"; }
nope() { echo "FAIL: $1"; fail=1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# One value out of the `osv` step: a jq program from its run block, or env:NAME.
from_step() {
  python3 - "$WF" "$1" <<'PY'
import re, sys, yaml
wf, want = sys.argv[1], sys.argv[2]
steps = yaml.safe_load(open(wf))["jobs"]["automerge"]["steps"]
step = next(s for s in steps if s.get("id") == "osv")
if want.startswith("env:"):
    print(step["env"][want[4:]])
else:
    m = re.search(want + r"='(.*?)'\n", step["run"], re.S)
    print(m.group(1) if m else "")
PY
}

# ------------------------------------------------------------------ 1. which files get scanned
FILES_JQ=$(from_step OSV_FILES_JQ)
if [ -z "$FILES_JQ" ]; then echo "FAIL: could not find OSV_FILES_JQ in $WF — renamed?"; exit 1; fi
got=$(jq -c "$FILES_JQ" "$FX/pr-files.json")
want='[{"path":"package-lock.json","base":"package-lock.json","as":null,"safe":true},{"path":"app/uv.lock","base":null,"as":null,"safe":true},{"path":"api/requirements-dev.txt","base":"api/requirements.txt","as":null,"safe":true},{"path":"notrequirements.txt","base":"notrequirements.txt","as":null,"safe":true},{"path":"requirements/base.txt","base":"requirements/base.txt","as":"requirements.txt","safe":true},{"path":"pkgs/a/pnpm-lock.yaml","base":null,"as":null,"safe":true},{"path":"evil/../package-lock.json","base":"evil/../package-lock.json","as":null,"safe":false}]'
if [ "$got" = "$want" ]; then
  ok "the file rule picks the seven lockfiles across both pages: a renamed one is read at its old name, an added or copied one has no base copy, any *requirements*.txt name, a requirements/ folder's base.txt told to read as requirements.txt, and a '..' path marked unsafe (the step then refuses to scan rather than skipping it)"
  ok "…and leaves out package.json, a workflow file, a removed yarn.lock, docs/notes.txt and docs/uv.lock.md"
else
  nope "the file rule changed what it picks"; echo "  got:  $got"; echo "  want: $want"
fi
got=$(jq -c "$FILES_JQ" <<< '[[{"filename":".github/workflows/ci.yml","status":"modified"}]]')
if [ "$got" = "[]" ]; then ok "a GitHub Actions bump has nothing to scan"; else nope "a workflow-only PR picked files: $got"; fi

# --------------------------------------------------------------- 2. which advisories are new
NEW_JQ=$(from_step OSV_NEW_JQ)
if [ -z "$NEW_JQ" ]; then echo "FAIL: could not find OSV_NEW_JQ in $WF — renamed?"; exit 1; fi
new_of() {  # <base json> <head json> <base prefix> <head prefix> → "file|name|id ..." sorted
  jq -c -n --slurpfile b "$1" --slurpfile h "$2" --arg bp "$3" --arg hp "$4" "$NEW_JQ" \
    | jq -r '[.[] | "\(.file)|\(.name)|\(.id)"] | sort | join(" ")'
}
got=$(new_of "$FX/scan-base.json" "$FX/scan-head.json" /W/base/ /W/head/)
want="app/uv.lock|requests|PYSEC-fixture-2 package-lock.json|flatmap-stream|MAL-2025-20690 package-lock.json|leftpad-evil|GHSA-fixt-ure0-new1 pkgs/a/pnpm-lock.yaml|lodash|GHSA-fixt-ure0-old1"
if [ "$got" = "$want" ]; then
  ok "four new findings, each for its own reason:"
  echo "    a new package's advisory (leftpad-evil), listed twice, counted once"
  echo "    every advisory in a lockfile the PR adds (app/uv.lock has no base copy)"
  echo "    an advisory the same package already had in a DIFFERENT lockfile (pkgs/a/pnpm-lock.yaml)"
  echo "    a malicious-package report that was already there (MAL- counts either way)"
  ok "…and not: lodash's advisory that survives its bump (same file, same id, new version), nor django's under a renamed file, nor one the bump fixed"
else
  nope "the new-advisory rule changed its answer"; echo "  got:  $got"; echo "  want: $want"
fi
got=$(new_of "$FX/scan-head.json" "$FX/scan-head.json" /W/head/ /W/head/)
if [ "$got" = "package-lock.json|flatmap-stream|MAL-2025-20690" ]; then
  ok "a PR that changes nothing OSV knows about adds nothing, except a MAL- report, which always stops it"
else
  nope "identical scans should leave only the MAL- report; got: $got"
fi
echo '{"results":[]}' > "$WORK/empty.json"
got=$(new_of "$FX/scan-base.json" "$WORK/empty.json" /W/base/ /W/head/)
if [ -z "$got" ]; then ok "a clean head adds nothing"; else nope "a clean head added: $got"; fi

# ------------------------------------------------------------------------------ 3. the wiring
python3 - "$WF" <<'PY' || fail=1
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = wf["jobs"]["automerge"]["steps"]
by_name = {s.get("name", ""): s for s in steps}
osv = next(s for s in steps if s.get("id") == "osv")
inputs = (wf.get("on") or wf.get(True))["workflow_call"]["inputs"]
bad = 0
def check(cond, good, failed):
    global bad
    print(("ok: " + good) if cond else ("FAIL: " + failed))
    bad += 0 if cond else 1
order = [s.get("id") or s.get("name") for s in steps]
check(order.index("osv") < order.index("Approve and enable auto-merge"),
      "the scan runs before anything is approved", "the scan moved after the approval")
# Step 1b (round 2 of the 2026-11-12 review): a rebase keeps an earlier head's auto-merge
# queued, so it has to come off before anything slow, or the new head merges unscanned.
UNQUEUE = "Take an earlier head's queued auto-merge off before deciding anything"
check(UNQUEUE in by_name, "a new head's queued auto-merge is taken off (step 1b exists)", "step 1b is gone")
if UNQUEUE in by_name:
    un = by_name[UNQUEUE]
    check(order.index(UNQUEUE) < order.index("Make sure the labels exist (idempotent)") < order.index("osv"),
          "…as the first step after the input check, before the labels and the scan",
          "step 1b moved later: " + str(order.index(UNQUEUE)))
    check(un.get("if") == "github.event.action != 'opened'",
          "…on every event but a PR's opening (which has no earlier queue)",
          "step 1b's condition changed: " + str(un.get("if")))
    check("gh pr merge --disable-auto" in un["run"] and un["run"].count("exit 1") == 2,
          "…and it turns the run red when it cannot read or remove the queue",
          "step 1b no longer fails red on both a failed read and a failed removal")
check(osv.get("if") == "steps.gate.outputs.ok == 'true'",
      "the scan runs whenever the CI gate is clear", "the scan's condition changed: " + str(osv.get("if")))
for name in ("Approve and enable auto-merge", "Note (and optionally nudge) a PR that is stale and red",
             "Watch the required checks and label a failure"):
    cond = by_name[name].get("if", "")
    check("steps.osv.outputs.clear == 'true'" in cond,
          f"'{name}' waits for the scan to say clear",
          f"'{name}' no longer waits for the scan: {cond}")
check(all("actions/checkout" not in str(s.get("uses", "")) for s in steps),
      "still no checkout step anywhere", "a checkout step appeared in a pull_request_target workflow")
run = osv["run"]
check('env -i PATH="$PATH" HOME="$HOME"' in run,
      "the scanner runs with an empty environment (no write token in it)", "the scanner lost its empty environment")
check('"$work/bin/osv-scanner" scan source --no-call-analysis=all --no-resolve' in run,
      "the scanner runs with call analysis and manifest resolution off", "the scanner's flags changed")
check("sha256sum -c" in run, "the download is checked against the pinned checksum", "the checksum check is gone")
check(inputs["osv-scan"]["default"] is True, "the scan is on by default", "the scan is no longer on by default")
for v in ("verdict=unread", "verdict=flagged", "verdict=clean", "verdict=nothing", "verdict=off"):
    check(v in run, f"the step can still say {v}", f"the step can no longer say {v}")
check(run.count('"clear=true"') == 3,
      "exactly three answers clear a merge (off, nothing, clean)",
      f"'clear=true' appears {run.count(chr(34) + 'clear=true' + chr(34))} times, expected 3")
sys.exit(1 if bad else 0)
PY

# --------------------------------------------------------------------------------- 4. --live
if [ "${1:-}" = "--live" ]; then
  ver=$(from_step env:OSV_VERSION); sum=$(from_step env:OSV_SHA256)
  base_url="https://github.com/google/osv-scanner/releases/download/$ver"
  if curl -fsSL --retry 2 -o "$WORK/osv-scanner" "$base_url/osv-scanner_linux_amd64"; then
    if command -v sha256sum > /dev/null; then got=$(sha256sum "$WORK/osv-scanner" | cut -d' ' -f1)
    else got=$(shasum -a 256 "$WORK/osv-scanner" | cut -d' ' -f1); fi
    if [ "$got" = "$sum" ]; then ok "the pinned checksum matches OSV-Scanner $ver as downloaded"
    else nope "OSV-Scanner $ver downloads as $got, but the workflow pins $sum"; fi
    rel=$(curl -fsSL --retry 2 "$base_url/osv-scanner_SHA256SUMS" | awk '$2 == "osv-scanner_linux_amd64" {print $1}')
    if [ "$rel" = "$sum" ]; then ok "…and the release's own SHA256SUMS says the same"
    else nope "the release's SHA256SUMS says '$rel' for osv-scanner_linux_amd64"; fi
  else
    nope "could not download OSV-Scanner $ver"
  fi

  # OSV_LOCAL_SCANNER=<path to the same version for this machine> runs the live scans off
  # Linux too (the checksum above is still the linux_amd64 one the workflow downloads).
  if [ -n "${OSV_LOCAL_SCANNER:-}" ]; then cp "$OSV_LOCAL_SCANNER" "$WORK/osv-scanner"; fi
  if { [ "$(uname -s)/$(uname -m)" = "Linux/x86_64" ] || [ -n "${OSV_LOCAL_SCANNER:-}" ]; } && [ -s "$WORK/osv-scanner" ]; then
    chmod +x "$WORK/osv-scanner"
    have_scanner=1
    pkg() { printf '"node_modules/%s":{"version":"%s","resolved":"https://registry.npmjs.org/%s/-/%s-%s.tgz","integrity":"sha512-fixture"}' "$1" "$2" "$1" "$1" "$2"; }
    lock() {  # <file> <entries...>
      mkdir -p "$(dirname "$1")"
      local f=$1; shift
      local IFS=,
      printf '{"name":"fixture","lockfileVersion":3,"requires":true,"packages":{"":{"name":"fixture"},%s}}\n' "$*" > "$f"
    }
    run_scan() {  # <json out> <log out> <lockfile>; echoes the exit code
      local rc=0
      env -i PATH="$PATH" HOME="$HOME" TMPDIR="$WORK" "$WORK/osv-scanner" scan source \
        --no-call-analysis=all --no-resolve --format json --output-file "$1" -L "$3" > "$2" 2>&1 || rc=$?
      echo "$rc"
    }
    read_count() { grep -F "Scanned $2 file and found " "$1" | tail -1 | sed 's/.* and found //; s/ .*//'; }

    lock "$WORK/live/base/package-lock.json" "$(pkg ms 2.1.3)"
    lock "$WORK/live/head/package-lock.json" "$(pkg ms 2.1.3)" "$(pkg lodash 4.17.15)" "$(pkg flatmap-stream 0.1.1)"
    mkdir -p "$WORK/live/broken"; printf '{ not json' > "$WORK/live/broken/package-lock.json"

    rc=$(run_scan "$WORK/base.json" "$WORK/base.log" "$WORK/live/base/package-lock.json")
    n=$(read_count "$WORK/base.log" "$WORK/live/base/package-lock.json")
    if [ "$rc" = 0 ] && [ "$n" = 1 ]; then ok "live: a clean lockfile exits 0, and the log line the step reads says 1 package"
    else nope "live: clean lockfile exited $rc, read '$n' packages"; cat "$WORK/base.log"; fi

    rc=$(run_scan "$WORK/head.json" "$WORK/head.log" "$WORK/live/head/package-lock.json")
    n=$(read_count "$WORK/head.log" "$WORK/live/head/package-lock.json")
    ids=$(jq -r '[.results[].packages[] | "\(.package.name):\(.vulnerabilities[].id)"] | join(" ")' "$WORK/head.json")
    if [ "$rc" = 1 ] && [ "$n" = 3 ] && grep -q 'lodash:GHSA-p6mc-m468-83gw' <<< "$ids" && grep -q 'flatmap-stream:MAL-' <<< "$ids"; then
      ok "live: lodash 4.17.15 comes back with GHSA-p6mc-m468-83gw and flatmap-stream 0.1.1 with a MAL- report (exit 1, 3 packages read)"
    else
      nope "live: the vulnerable lockfile exited $rc, read '$n' packages, found: $ids"; cat "$WORK/head.log"
    fi

    got=$(new_of "$WORK/base.json" "$WORK/head.json" "$WORK/live/base/" "$WORK/live/head/" | tr ' ' '\n' | grep -c . || true)
    if [ "$got" -ge 2 ] && new_of "$WORK/base.json" "$WORK/head.json" "$WORK/live/base/" "$WORK/live/head/" | grep -q 'package-lock.json|flatmap-stream|MAL-'; then
      ok "live: end to end, the step's rule flags the malicious package and lodash's advisories as added by the PR"
    else
      nope "live: end to end the rule found $got new findings"
    fi

    mkdir -p "$WORK/live/req/requirements"; printf 'django==2.2.0\n' > "$WORK/live/req/requirements/base.txt"
    rc=$(run_scan "$WORK/req.json" "$WORK/req.log" "requirements.txt:$WORK/live/req/requirements/base.txt")
    n=$(read_count "$WORK/req.log" "$WORK/live/req/requirements/base.txt")
    if [ "$rc" = 1 ] && [ "$n" = 1 ]; then ok "live: requirements/base.txt read as requirements.txt finds Django 2.2.0's advisories, and the log names the plain path"
    else nope "live: requirements/base.txt as requirements.txt exited $rc, read '$n' packages"; cat "$WORK/req.log"; fi

    rc=$(run_scan "$WORK/broken.json" "$WORK/broken.log" "$WORK/live/broken/package-lock.json")
    if [ "$rc" != 0 ] && [ "$rc" != 1 ]; then ok "live: a broken lockfile exits $rc, which the step reads as a scan that did not happen"
    else nope "live: a broken lockfile exited $rc, which the step would read as a real answer"; fi
  else
    echo "skip: the live scan runs only on Linux x86_64 (this is $(uname -s)/$(uname -m)); the checksum was still checked"
  fi
fi

# ------------------------------------------------- 5. the steps' own bash, with stand-in gh and curl
# Pulled out of the workflow and run as they are, against a stand-in `gh` that serves a pull
# request from files in $DATA and records every call, and a stand-in `curl` that serves the
# scanner from $WORK (or fails, to be an outage). The parts that need no scanner always run;
# the scans run where --live found one (Linux, or OSV_LOCAL_SCANNER).
step_run() {  # <step name or id> <file to write>
  python3 - "$WF" "$1" "$2" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["automerge"]["steps"]
s = next(x for x in steps if x.get("id") == sys.argv[2] or x.get("name") == sys.argv[2])
open(sys.argv[3], "w").write(s["run"])
PY
}
SH="$WORK/shims"; mkdir -p "$SH"
step_run "Take an earlier head's queued auto-merge off before deciding anything" "$WORK/unqueue.sh"
step_run osv "$WORK/osv.sh"
cat > "$SH/gh" <<'EOF'
#!/bin/bash
# stand-in gh: one pull request, served from $DATA; every call goes to $DATA/gh.log
echo "gh $*" >> "$DATA/gh.log"
a="$*"
case "$a" in
  "pr view"*autoMergeRequest*) case "$(cat "$DATA/automerge" 2>/dev/null)" in unreadable) exit 1 ;; stuck|true) echo true ;; *) echo false ;; esac ;;
  "pr view"*labels*) cat "$DATA/labels" 2>/dev/null ;;
  "pr merge --disable-auto"*) [ "$(cat "$DATA/automerge")" = stuck ] && exit 1; echo false > "$DATA/automerge" ;;
  "pr edit"*) : ;;
  *"/pulls/7/files"*) cat "$DATA/files.json" ;;
  *"/compare/"*) echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
  *"/contents/"*"ref=aaaa"*) p=${a#*contents/}; p=${p%%\?ref=*}; cat "$DATA/head/$p" 2>/dev/null || exit 1 ;;
  *"/contents/"*"ref=bbbb"*) p=${a#*contents/}; p=${p%%\?ref=*}; cat "$DATA/base/$p" 2>/dev/null || exit 1 ;;
  *) echo "stand-in gh: unexpected call: $a" >&2; exit 9 ;;
esac
EOF
cat > "$SH/curl" <<'EOF'
#!/bin/bash
# stand-in curl: serves $CURL_SERVES to -o, or fails like an outage when it is unset
[ -n "${CURL_SERVES:-}" ] || exit 22
while [ $# -gt 0 ]; do [ "$1" = -o ] && { cp "$CURL_SERVES" "$2"; exit; }; shift; done
exit 2
EOF
command -v timeout > /dev/null || printf '#!/bin/bash\nshift; exec "$@"\n' > "$SH/timeout"
command -v sha256sum > /dev/null || printf '#!/bin/bash\nexec shasum -a 256 "$@"\n' > "$SH/sha256sum"
chmod +x "$SH"/*
case_dir() { rm -rf "$WORK/case"; mkdir -p "$WORK/case/head" "$WORK/case/base" "$WORK/case/runner"; : > "$WORK/case/gh.log"; : > "$WORK/case/out"; echo "$WORK/case"; }
run_step() {  # <script> [VAR=value...]; exit code in $rc
  local script=$1; shift
  rc=0
  env -i PATH="$SH:$PATH" HOME="$HOME" DATA="$WORK/case" GITHUB_OUTPUT="$WORK/case/out" RUNNER_TEMP="$WORK/case/runner" \
    REPO=khglynn/fixture PR_URL=https://github.com/khglynn/fixture/pull/7 PR_NUMBER=7 \
    HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa BASE_BRANCH=main IN_OSV_SCAN=true \
    LABEL_OSV=dependabot-osv-flagged LABEL_UNPARSED=dependabot-needs-human \
    OSV_VERSION=v2.7.0 OSV_SHA256="${STUB_SUM:-none}" "$@" bash "$script" > "$WORK/case/stdout" 2>&1 || rc=$?
}
out_has() { grep -qxF "$1" "$WORK/case/out"; }

# The race the 2026-11-12 round-2 review found: a rebase arrives with an earlier head queued.
D=$(case_dir); echo true > "$D/automerge"; run_step "$WORK/unqueue.sh"
if [ "$rc" = 0 ] && grep -q "^gh pr merge --disable-auto" "$D/gh.log" && [ "$(cat "$D/automerge")" = false ]; then
  ok "stand-in: a new head arriving while an earlier one is queued has its auto-merge taken off before any scan"
else nope "stand-in: a queued earlier head was not taken off (exit $rc)"; cat "$D/stdout" "$D/gh.log"; fi
D=$(case_dir); echo false > "$D/automerge"; run_step "$WORK/unqueue.sh"
if [ "$rc" = 0 ] && ! grep -q "disable-auto" "$D/gh.log"; then ok "stand-in: nothing queued, nothing taken off"
else nope "stand-in: an unqueued PR was touched (exit $rc)"; cat "$D/gh.log"; fi
D=$(case_dir); echo unreadable > "$D/automerge"; run_step "$WORK/unqueue.sh"
if [ "$rc" != 0 ]; then ok "stand-in: when it cannot tell whether a merge is queued, the run goes red"
else nope "stand-in: an unreadable queue state passed quietly"; fi
D=$(case_dir); echo stuck > "$D/automerge"; run_step "$WORK/unqueue.sh"
if [ "$rc" != 0 ]; then ok "stand-in: when the queue will not come off, the run goes red"
else nope "stand-in: a queue that would not come off passed quietly"; fi

# The scan step's own shell, before any scanner runs.
D=$(case_dir); run_step "$WORK/osv.sh" IN_OSV_SCAN=false
if out_has verdict=off && out_has clear=true; then ok "stand-in: osv-scan: false clears without scanning"; else nope "stand-in: osv-scan: false said $(tr '\n' ' ' < "$D/out")"; fi
D=$(case_dir); echo '[[{"filename":".github/workflows/ci.yml","status":"modified"}]]' > "$D/files.json"; run_step "$WORK/osv.sh"
if out_has verdict=nothing && out_has clear=true; then ok "stand-in: a GitHub Actions bump has nothing to scan, and clears"; else nope "stand-in: an Actions-only PR said $(tr '\n' ' ' < "$D/out")"; fi
# Round 2's second finding: an ADDED requirements/base.txt has an empty base. With tab-split
# fields its parser hint slid into the base slot and the step went looking for a root
# requirements.txt at the merge base. Now it must reach the download (failed here on purpose).
D=$(case_dir); mkdir -p "$D/head/requirements"; printf 'django==2.2.0\n' > "$D/head/requirements/base.txt"
echo '[[{"filename":"requirements/base.txt","status":"added"}]]' > "$D/files.json"; run_step "$WORK/osv.sh"
if out_has verdict=unread && grep -q "could not download OSV-Scanner" "$D/stdout" && ! grep -q "ref=bbbb" "$D/gh.log"; then
  ok "stand-in: an added requirements/base.txt keeps its empty base: no merge-base fetch, straight on to the scanner"
  ok "stand-in: the scanner unreachable (download failed) is unread, not clear"
else nope "stand-in: the added requirements file went wrong: $(grep -E 'warning|osv:' "$D/stdout" | head -2)"; cat "$D/gh.log"; fi

# With a scanner: the whole step, ending in a verdict.
if [ "${have_scanner:-0}" = 1 ]; then
  if command -v sha256sum > /dev/null; then STUB_SUM=$(sha256sum "$WORK/osv-scanner" | cut -d' ' -f1)
  else STUB_SUM=$(shasum -a 256 "$WORK/osv-scanner" | cut -d' ' -f1); fi
  files_modified='[[{"filename":"package-lock.json","status":"modified"},{"filename":"package.json","status":"modified"}]]'
  D=$(case_dir); echo "$files_modified" > "$D/files.json"
  lock "$D/base/package-lock.json" "$(pkg ms 2.1.3)" "$(pkg lodash 4.17.15)"; lock "$D/head/package-lock.json" "$(pkg ms 2.1.3)" "$(pkg lodash 4.17.20)"
  echo dependabot-needs-human > "$D/labels"
  run_step "$WORK/osv.sh" CURL_SERVES="$WORK/osv-scanner" STUB_SUM="$STUB_SUM"
  if out_has verdict=clean && out_has clear=true && grep -q -- "--remove-label dependabot-needs-human" "$D/gh.log"; then
    ok "stand-in live: a bump that keeps lodash's old advisories is clean, and an earlier run's needs-human comes off"
  else nope "stand-in live: the keep-old-advisories case said $(tr '\n' ' ' < "$D/out")"; tail -5 "$D/stdout"; fi
  D=$(case_dir); echo "$files_modified" > "$D/files.json"
  lock "$D/base/package-lock.json" "$(pkg ms 2.1.3)"; lock "$D/head/package-lock.json" "$(pkg ms 2.1.3)" "$(pkg flatmap-stream 0.1.1)"
  run_step "$WORK/osv.sh" CURL_SERVES="$WORK/osv-scanner" STUB_SUM="$STUB_SUM"
  mal=$(awk '/^findings<<OSV_FINDINGS_EOF$/{f=1;next} /^OSV_FINDINGS_EOF$/{f=0} f' "$D/out" | grep '^MAL-' | head -1)
  fields=$(printf '%s' "$mal" | awk -F $'\x1f' '{print NF}')
  if out_has verdict=flagged && out_has clear=false && [ "$fields" = 5 ]; then
    ok "stand-in live: a malicious package the PR brings in is flagged, its finding in five unit-separated fields"
  else nope "stand-in live: the malicious-package case said $(tr '\n' ' ' < "$D/out" | cut -c1-200)"; fi
  D=$(case_dir); mkdir -p "$D/head/requirements"; printf 'django==2.2.0\n' > "$D/head/requirements/base.txt"
  echo '[[{"filename":"requirements/base.txt","status":"added"}]]' > "$D/files.json"
  run_step "$WORK/osv.sh" CURL_SERVES="$WORK/osv-scanner" STUB_SUM="$STUB_SUM"
  if out_has verdict=flagged; then ok "stand-in live: an added requirements/base.txt is read as requirements.txt, and every advisory in it counts as added"
  else nope "stand-in live: the added requirements file said $(tr '\n' ' ' < "$D/out" | cut -c1-200)"; tail -5 "$D/stdout"; fi
fi

if [ "$fail" -ne 0 ]; then echo; echo "check-osv: FAILED"; exit 1; fi
echo; echo "check-osv: all ok"
