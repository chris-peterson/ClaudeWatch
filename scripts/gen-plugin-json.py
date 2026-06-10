#!/usr/bin/env python3
"""Project plugin.yml → .claude-plugin/plugin.json.

plugin.yml is the canonical descriptor; plugin.json is generated and committed
(Claude Code reads the committed file at install). Run via `just plugin-json`,
or pass --check to verify the committed file is in sync (used by CI and the
pre-commit hook).
"""
import json
import pathlib
import sys

import yaml

# plugin.json carries only the packaging fields, in this order. The rest of
# plugin.yml (marketplace:, suite:) projects into other targets, not here.
PACKAGING_FIELDS = (
    "name",
    "version",
    "description",
    "author",
    "repository",
    "icon",
    "license",
    "keywords",
)

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "plugin.yml"
TARGET = ROOT / ".claude-plugin" / "plugin.json"


def build() -> str:
    spec = yaml.safe_load(SOURCE.read_text())
    out = {}
    for field in PACKAGING_FIELDS:
        if field not in spec:
            continue
        value = spec[field]
        # author is a plain string in plugin.yml; plugin.json wants an object.
        if field == "author" and isinstance(value, str):
            value = {"name": value}
        out[field] = value
    return json.dumps(out, indent=2) + "\n"


def main() -> int:
    generated = build()
    if "--check" in sys.argv[1:]:
        current = TARGET.read_text() if TARGET.exists() else ""
        if current != generated:
            sys.stderr.write(
                f"{TARGET} is out of sync with plugin.yml.\n"
                "Run `just plugin-json` and commit the result.\n"
            )
            return 1
        return 0
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(generated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
