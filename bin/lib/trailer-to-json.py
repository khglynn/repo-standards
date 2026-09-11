#!/usr/bin/env python3
"""Rebuild what `dependabot/fetch-metadata` would emit as `updated-dependencies-json`.

    <commit message on stdin> | trailer-to-json.py --branch <branch> --title <title>

Prints a JSON array of {dependencyName, dependencyType, updateType, prevVersion, newVersion}.

WHY IT IS NOT JUST THE TRAILER (learned 2026-09-11, and it changed real predictions):
fetch-metadata v3 does NOT pass the trailer's `update-type` straight through. In
src/dependabot/update_metadata.ts at the pinned v3.1.0 SHA:

    const updateType = dependency['update-type'] || calculateUpdateType(lastVersion, nextVersion)

So a trailer with a null `update-type` — which Dependabot writes routinely; eachie #116 is
one — does not mean "unclassifiable". It means "compute it from the versions". Reading only
the trailer reports `unknown` where the workflow will say `major`, and — much worse in the
other direction — reports `unknown` on a `1.2.3 → 1.2.4` bump that the workflow computes as
`semver-patch` and MERGES. A tool whose whole job is to predict the gate must not be
reassuring about a PR that will sail through.

Where the versions come from, mirroring the same file:
  * newVersion  ← the trailer's `dependency-version`, else the metadata link, else (first
                  dependency only) the "to" version parsed out of the commit/title.
  * prevVersion ← the metadata link "Updates `x` from A to B" (multi-dependency PRs), else
                  (first dependency only) the "from" version from `Bumps … from A to B.`
                  or an `Update X requirement from A to B` line, or the PR title.
"""
import argparse
import json
import re
import sys

import yaml

# Mirrors updateRegex / bumpFragment in update_metadata.ts.
UPDATE_RE = re.compile(
    r"\b[Uu]pdate .* requirement from \S*? ?(?P<from>v?\d\S*) to \S*? ?(?P<to>v?\d\S*)"
)
BUMP_RE = re.compile(r"^Bumps .* from (?P<from>v?\d[^ ]*) to (?P<to>v?\d[^ ]*)\.$", re.M)
LINK_RE = re.compile(r"^Updates `(?P<name>\S+)` (?:from (?P<from>\S+) )?to (?P<to>\S+)$", re.M)


def calculate_update_type(last: str, nxt: str) -> str:
    """A verbatim port of calculateUpdateType() from update_metadata.ts. Keep it verbatim:
    the moment this drifts, this tool stops predicting the workflow and starts guessing."""
    if not last or not nxt or last == nxt:
        return ""
    last_parts = last.replace("v", "").split(".")
    next_parts = nxt.replace("v", "").split(".")
    if last_parts[0] != next_parts[0]:
        return "version-update:semver-major"
    if len(last_parts) < 2 or len(next_parts) < 2 or last_parts[1] != next_parts[1]:
        return "version-update:semver-minor"
    return "version-update:semver-patch"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--branch", default="")
    ap.add_argument("--title", default="")
    args = ap.parse_args()
    msg = sys.stdin.read()

    m = re.search(r"^updated-dependencies:\n(.*?)(?:\n\n|\Z)", msg, re.S | re.M)
    if not m:
        print("[]")
        return 0
    items = yaml.safe_load("updated-dependencies:\n" + m.group(1))["updated-dependencies"]

    bump = BUMP_RE.search(msg)
    upd = UPDATE_RE.search(msg.split("\n")[0])
    title_upd = UPDATE_RE.search(args.title) if (not bump and not upd and args.title) else None
    chosen = bump or upd or title_upd
    prev_fallback = chosen.group("from") if chosen else ""
    next_fallback = chosen.group("to") if chosen else ""

    # "Updates `name` from A to B" lines, in order, one list per dependency name.
    links: dict[str, list[tuple[str, str]]] = {}
    for link in LINK_RE.finditer(msg):
        links.setdefault(link.group("name"), []).append(
            (link.group("from") or "", link.group("to"))
        )

    out = []
    counters: dict[str, int] = {}
    for index, dep in enumerate(items):
        name = dep.get("dependency-name")
        n = counters.get(name, 0)
        counters[name] = n + 1
        linked = links.get(name, [])
        link_prev, link_next = linked[n] if n < len(linked) else ("", "")

        prev = link_prev or (prev_fallback if index == 0 else "")
        nxt = str(dep.get("dependency-version") or link_next or (next_fallback if index == 0 else ""))
        update_type = dep.get("update-type") or calculate_update_type(prev, nxt)

        out.append(
            {
                "dependencyName": name,
                "dependencyType": dep.get("dependency-type"),
                "updateType": update_type,
                "prevVersion": prev,
                "newVersion": nxt,
            }
        )
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
