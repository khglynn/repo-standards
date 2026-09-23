#!/usr/bin/env python3
"""Prove the templates in this repo are still valid before they get stamped into repos.

The caller stub and the dependabot fragments are TEMPLATES, so nothing else in CI parses
them: actionlint only reads `.github/workflows/`, and a fragment is not even a whole YAML
document on its own. This is the check that stops a broken template from being copied into
a dozen repos before anyone notices. Written 2026-09-11.

Run from the repo root:  python3 bin/lib/check-templates.py
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
FAILURES: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        FAILURES.append(message)


def check_caller_stub() -> None:
    path = ROOT / "templates" / "caller-stub.yml"
    doc = yaml.safe_load(path.read_text())
    # PyYAML follows YAML 1.1, where a bare `on:` key is the boolean True. That is a quirk
    # of the parser, not of the file — GitHub reads it as the string "on".
    trigger = doc.get("on", doc.get(True))
    check(bool(trigger), "caller-stub.yml: lost its trigger entirely")
    check("pull_request_target" in (trigger or {}),
          "caller-stub.yml: must trigger on pull_request_target, or it cannot approve anything")
    perms = doc.get("permissions", {})
    for needed in ("contents", "pull-requests", "issues"):
        check(perms.get(needed) == "write", f"caller-stub.yml: needs `{needed}: write`")
    # …and NOTHING beyond those three. The shared workflow declares no permissions of its own
    # (2026-09-22), so the stub's grant IS the job's token: an extra scope here is an extra
    # scope in every repo enrolled from this template. The failed-test watch's two reads
    # ship commented out, like the watch itself.
    extra = sorted(set(perms) - {"contents", "pull-requests", "issues"})
    check(not extra, f"caller-stub.yml: grants more than the default workflow uses: {extra}")
    text = path.read_text()
    for recipe in ("# checks: read", "# statuses: read", "watch-minutes:"):
        check(recipe in text, f"caller-stub.yml: lost the commented recipe line `{recipe}`")
    uses = doc.get("jobs", {}).get("automerge", {}).get("uses", "")
    check("khglynn/repo-standards/.github/workflows/dependabot-automerge.yml" in uses,
          "caller-stub.yml: no longer points at the shared workflow")
    print("caller-stub.yml: ok")


def check_dependabot_fragments() -> None:
    frag_dir = ROOT / "templates" / "dependabot"
    header = (frag_dir / "_header.yml").read_text()
    fragments = sorted(p for p in frag_dir.glob("*.yml") if p.name != "_header.yml")
    check(bool(fragments), "templates/dependabot/: no fragments found at all")
    for frag in fragments:
        # A fragment is one list item. Splice it onto the header exactly the way bin/enroll
        # does, then parse the result — that is the only thing that proves it composes.
        spliced = header + "\n" + frag.read_text().replace("{{DIRECTORY}}", "/")
        try:
            doc = yaml.safe_load(spliced)
        except yaml.YAMLError as exc:
            FAILURES.append(f"{frag.name}: does not splice into valid YAML — {exc}")
            continue
        check(doc.get("version") == 2, f"{frag.name}: spliced file lost `version: 2`")
        updates = doc.get("updates") or []
        check(len(updates) == 1, f"{frag.name}: expected exactly one update entry, got {len(updates)}")
        if updates:
            entry = updates[0]
            check("package-ecosystem" in entry, f"{frag.name}: no package-ecosystem")
            check(entry.get("labels") == ["dependencies"],
                  f"{frag.name}: must carry the `dependencies` label — it is how a human "
                  f"skimming the PR list sees at a glance which ones are the bot's")
            check("cooldown" in entry, f"{frag.name}: lost its cooldown — that is the supply-chain soak")
        print(f"{frag.name}: ok")


def main() -> int:
    check_caller_stub()
    check_dependabot_fragments()
    if FAILURES:
        print("\nFAILED:", file=sys.stderr)
        for f in FAILURES:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("\nall templates ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
