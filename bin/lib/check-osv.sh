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
want='[{"path":"package-lock.json","base":"package-lock.json","safe":true},{"path":"app/uv.lock","base":null,"safe":true},{"path":"api/requirements-dev.txt","base":"api/requirements.txt","safe":true},{"path":"pkgs/a/pnpm-lock.yaml","base":null,"safe":true},{"path":"evil/../package-lock.json","base":"evil/../package-lock.json","safe":false}]'
if [ "$got" = "$want" ]; then
  ok "the file rule picks the five lockfiles across both pages: a renamed one is read at its old name, an added or copied one has no base copy, and a '..' path is marked unsafe (the step then refuses to scan rather than skipping it)"
  ok "…and leaves out package.json, a workflow file, a removed yarn.lock, notrequirements.txt and docs/uv.lock.md"
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

    rc=$(run_scan "$WORK/broken.json" "$WORK/broken.log" "$WORK/live/broken/package-lock.json")
    if [ "$rc" != 0 ] && [ "$rc" != 1 ]; then ok "live: a broken lockfile exits $rc, which the step reads as a scan that did not happen"
    else nope "live: a broken lockfile exited $rc, which the step would read as a real answer"; fi
  else
    echo "skip: the live scan runs only on Linux x86_64 (this is $(uname -s)/$(uname -m)); the checksum was still checked"
  fi
fi

if [ "$fail" -ne 0 ]; then echo; echo "check-osv: FAILED"; exit 1; fi
echo; echo "check-osv: all ok"
