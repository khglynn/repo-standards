#!/usr/bin/env python3
"""Read a repo's file list on stdin, print the package ecosystems Dependabot should watch.

Output: one `ecosystem<TAB>directory` line per finding, sorted, e.g.

    github-actions	/
    npm	/
    uv	/pipeline

Only the repo root and ONE level down are considered. Deeper than that and a manifest is
almost always a vendored copy, a fixture, or an example — pointing Dependabot at those
produces PRs for code nobody ships. Written 2026-09-11.
"""
import os
import re
import sys

# Directories that hold other people's code, build output, or test fixtures.
IGNORE = re.compile(
    r"^(node_modules|vendor|dist|build|out|\.next|\.venv|venv|_archive|third_party|fixtures|examples)/"
)

MANIFESTS = {
    "package.json": "npm",
    "pyproject.toml": "uv",     # NOT "pip" — uv/pyproject is its own Dependabot ecosystem
    "requirements.txt": "pip",
}

# Manifests Dependabot DOES support but this toolchain has no fragment for yet. They are
# reported on stderr rather than silently ignored: `bin/audit` counts a repo with one of
# these as "has a manifest", so staying quiet here meant `enroll` telling you a Go or Rust
# repo had "nothing to keep updated" — a confident wrong answer — and then installing a
# merge stub that would never see a Dependabot PR. Added 2026-09-11.
# To support one: add templates/dependabot/<ecosystem>.yml and move its row up into
# MANIFESTS above. The ecosystem names are Dependabot's own.
UNSUPPORTED = {
    "go.mod": "gomod",
    "Gemfile": "bundler",
    "Cargo.toml": "cargo",
    "composer.json": "composer",
    "pom.xml": "maven",
    "build.gradle": "gradle",
    "Dockerfile": "docker",
    "main.tf": "terraform",
}


def main() -> int:
    found = set()
    unsupported = set()
    has_workflows = False

    for line in sys.stdin:
        path = line.strip()
        if not path:
            continue
        if path.startswith(".github/workflows/") and path.endswith((".yml", ".yaml")):
            has_workflows = True
        if IGNORE.match(path):
            continue
        directory, base = os.path.split(path)
        if directory.count("/") >= 1:  # deeper than one level down
            continue
        where = "/" + directory if directory else "/"
        eco = MANIFESTS.get(base)
        if eco:
            found.add((eco, where))
        elif base in UNSUPPORTED:
            unsupported.add((UNSUPPORTED[base], where, base))

    # A directory holding a pyproject.toml is a uv project. A requirements.txt sitting
    # beside it is usually an export for deployment, and declaring both makes Dependabot
    # open two PRs for the same upgrade.
    found -= {("pip", d) for (eco, d) in found if eco == "uv"}

    if has_workflows:
        # For this ecosystem "/" means the repo root, not .github/workflows — a common
        # misreading that makes Dependabot silently find nothing.
        found.add(("github-actions", "/"))

    for eco, directory in sorted(found):
        print(f"{eco}\t{directory}")

    # stderr, deliberately: stdout is the machine-readable list `enroll` splices into a
    # dependabot.yml, and an ecosystem with no fragment must never reach it.
    for eco, directory, filename in sorted(unsupported):
        print(f"{filename} in {directory} — Dependabot ecosystem '{eco}', no template here yet",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
