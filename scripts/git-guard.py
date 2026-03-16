#!/usr/bin/env python3
"""
git-guard: PreToolUse hook for Claude Code

Enforces git safety rules loaded from a YAML config file.
Reads tool input JSON from stdin, outputs a hook decision to stdout.
"""

import json
import os
import re
import sys


def _unquote(s):
    if len(s) >= 2 and s[0] in ('"', "'") and s[-1] == s[0]:
        return s[1:-1]
    return s


def parse_rules_yml(path):
    """Parse rules.yml without external dependencies.

    Handles the specific format used by this plugin:
      rules:
        block:
          - pattern: '...'
            reason: ...
            ref: ...
        ask:
          - pattern: '...'
            reason: ...
            ref: ...
    """
    rules = {"block": [], "ask": []}
    current_section = None
    current_item = None

    with open(path) as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            stripped = line.strip()

            if not stripped or stripped.startswith("#"):
                continue

            indent = len(line) - len(line.lstrip())

            if indent == 2 and stripped in ("block:", "ask:"):
                current_section = stripped[:-1]
                current_item = None

            elif indent == 4 and stripped.startswith("- name:") and current_section is not None:
                current_item = {"name": _unquote(stripped[7:].strip()), "pattern": "", "reason": "", "ref": ""}
                rules[current_section].append(current_item)

            elif indent == 4 and stripped.startswith("- pattern:") and current_section is not None:
                current_item = {"name": "", "pattern": _unquote(stripped[10:].strip()), "reason": "", "ref": ""}
                rules[current_section].append(current_item)

            elif indent == 6 and stripped.startswith("pattern:") and current_item is not None:
                current_item["pattern"] = _unquote(stripped[8:].strip())

            elif indent == 6 and stripped.startswith("name:") and current_item is not None:
                current_item["name"] = _unquote(stripped[5:].strip())

            elif indent == 6 and stripped.startswith("reason:") and current_item is not None:
                current_item["reason"] = _unquote(stripped[7:].strip())

            elif indent == 6 and stripped.startswith("ref:") and current_item is not None:
                current_item["ref"] = _unquote(stripped[4:].strip())

    return rules


def _message(rule):
    return f"git-guard: {rule['reason']} — {rule['ref']}"


def main():
    rules_path = (
        sys.argv[1]
        if len(sys.argv) > 1
        else os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "rules.yml")
    )

    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        sys.exit(0)

    if data.get("tool_name") != "Bash":
        sys.exit(0)

    cmd = data.get("tool_input", {}).get("command", "")
    if not cmd or not re.search(r"\bgit\b", cmd):
        sys.exit(0)

    try:
        rules = parse_rules_yml(rules_path)
    except Exception as e:
        print(json.dumps({"decision": "block", "reason": f"git-guard: failed to load rules: {e}"}, separators=(",", ":")))
        sys.exit(0)

    for rule in rules.get("block", []):
        if re.search(rule["pattern"], cmd):
            print(json.dumps({"decision": "block", "reason": _message(rule)}, separators=(",", ":")))
            sys.exit(0)

    for rule in rules.get("ask", []):
        if re.search(rule["pattern"], cmd):
            print(json.dumps({"decision": "ask", "message": _message(rule)}, separators=(",", ":")))
            sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    main()
