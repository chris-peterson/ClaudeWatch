#!/usr/bin/env python3
"""PostToolUse dev hook — remind to update the secondary rule-set indexes.

Each shipped rule set is described in several hand-maintained places that drift
independently (README table, SPEC.md [SH-01], help-skill table). This hook fires
after a Write/Edit to a `watches/watch-*.yml` source file and injects a reminder
listing those places so a rule-set change doesn't silently leave them stale.

This guards development of ClaudeWatch itself — it is NOT part of the shipped
plugin (that is `hooks/hooks.json` + `scripts/watchdog.py`). Pure stdlib, exits 0.
"""
import json
import re
import sys

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

path = (data.get("tool_input") or {}).get("file_path", "") or ""

# Fire only on rule-set source files — not *.yml.disabled, not test files.
if not re.search(r"watches/watch-[^/]+\.yml$", path):
    sys.exit(0)

reminder = (
    f"Rule-set source changed ({path}). A rule set is described in several "
    "hand-maintained places that drift independently — update whichever the "
    "change affects:\n"
    "  1. README.md — rule-sets table (one row per set)\n"
    "  2. SPEC.md — [SH-01] enumeration (block/ask coverage prose)\n"
    "  3. skills/help/SKILL.md — rule-sets table (one-line summary)\n"
    "  4. tests/test-watch-<name>.sh — add/extend for a new or changed set ([SH-04])\n"
    "Then run `just test` and `just docs` (regenerates the docs reference from YAML)."
)

json.dump(
    {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": reminder,
        }
    },
    sys.stdout,
)
sys.exit(0)
