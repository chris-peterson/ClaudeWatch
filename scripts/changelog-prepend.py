#!/usr/bin/env python3
"""Prepend a release section to CHANGELOG.md from a GitHub Release body.

Run by .github/workflows/release.yml on `release: published`. Reads VERSION
(e.g. "0.13.3") and BODY (the release-notes markdown) from the environment and
inserts a `## <VERSION>` section directly under the top-level `# Changelog`
title. Idempotent: if a `## <VERSION>` section already exists, the file is left
unchanged, so re-publishing a release doesn't duplicate the entry.
"""
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"


def main() -> int:
    version = os.environ["VERSION"].strip()
    body = os.environ.get("BODY", "").strip()

    text = CHANGELOG.read_text()
    header = f"## {version}"
    if header in text:
        sys.stderr.write(f"CHANGELOG.md already has a {header} section; leaving unchanged.\n")
        return 0

    lines = text.splitlines()
    try:
        title_idx = next(i for i, line in enumerate(lines) if line.startswith("# "))
    except StopIteration:
        sys.stderr.write("CHANGELOG.md has no top-level '# ' title.\n")
        return 1

    title = lines[: title_idx + 1]
    rest = lines[title_idx + 1 :]
    while rest and not rest[0].strip():
        rest.pop(0)

    section = [header, ""]
    if body:
        section += [body, ""]

    new_lines = title + [""] + section + rest
    CHANGELOG.write_text("\n".join(new_lines).rstrip() + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
