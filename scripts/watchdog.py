#!/usr/bin/env python3
"""
claude-watchdog: PreToolUse hook for Claude Code

Generic rule engine that enforces safety rules loaded from YAML config files.
Reads tool input JSON from stdin, evaluates all rule sets in a directory,
and outputs a single coalesced JSON decision to stdout.
"""

import glob
import json
import os
import re
import sys


def _unquote(s):
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1].replace("''", "'")
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s


def parse_rules_yml(path):
    """Parse a watchdog rules YAML file without external dependencies.

    Handles the format:
      name: watch-name
      filter: 'optional-regex'
      rules:
        block:
          - name: ...
            pattern: '...'
            reason: ...
            ref: ...
        ask:
          - name: ...
            pattern: '...'
            reason: ...
            ref: ...
    """
    result = {"name": "", "filter": "", "rules": {"block": [], "ask": []}}
    current_section = None
    current_item = None

    with open(path) as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            stripped = line.strip()

            if not stripped or stripped.startswith("#"):
                continue

            indent = len(line) - len(line.lstrip())

            # top-level fields (indent 0)
            if indent == 0 and stripped.startswith("name:"):
                result["name"] = _unquote(stripped[5:].strip())
            elif indent == 0 and stripped.startswith("filter:"):
                result["filter"] = _unquote(stripped[7:].strip())
            elif indent == 0 and stripped == "rules:":
                pass

            # section headers (indent 2)
            elif indent == 2 and stripped in ("block:", "ask:"):
                current_section = stripped[:-1]
                current_item = None

            # list item start (indent 4)
            elif indent == 4 and stripped.startswith("- name:") and current_section is not None:
                current_item = {"name": _unquote(stripped[7:].strip()), "pattern": "", "reason": "", "ref": ""}
                result["rules"][current_section].append(current_item)

            elif indent == 4 and stripped.startswith("- pattern:") and current_section is not None:
                current_item = {"name": "", "pattern": _unquote(stripped[10:].strip()), "reason": "", "ref": ""}
                result["rules"][current_section].append(current_item)

            # item fields (indent 6)
            elif indent == 6 and stripped.startswith("pattern:") and current_item is not None:
                current_item["pattern"] = _unquote(stripped[8:].strip())

            elif indent == 6 and stripped.startswith("name:") and current_item is not None:
                current_item["name"] = _unquote(stripped[5:].strip())

            elif indent == 6 and stripped.startswith("reason:") and current_item is not None:
                current_item["reason"] = _unquote(stripped[7:].strip())

            elif indent == 6 and stripped.startswith("ref:") and current_item is not None:
                current_item["ref"] = _unquote(stripped[4:].strip())

            elif indent == 6 and stripped.startswith("except:") and current_item is not None:
                if current_section == "block":
                    print(f"warning: {result['name'] or path} — rule {current_item.get('name', '?')!r} has 'except' on a block rule (ignored — except only applies to ask rules)", file=sys.stderr)
                else:
                    current_item["except"] = _unquote(stripped[7:].strip())

    return result


def _message(label, rule):
    parts = [label, rule["reason"]]
    if rule.get("ref"):
        parts.append(rule["ref"])
    return " — ".join(parts)


def evaluate_rules(config, cmd):
    """Evaluate a single rule set against a command.

    Returns (blocks, asks) — lists of violation message strings.
    """
    blocks = []
    asks = []
    label = config.get("name") or "unknown"

    def _block(reason):
        blocks.append(reason)

    filt = config.get("filter")
    if filt:
        try:
            if not re.search(filt, cmd):
                return blocks, asks
        except re.error as e:
            _block(f"{label} — invalid filter regex: {e}")
            return blocks, asks

    rules = config.get("rules", {})

    for rule in rules.get("block", []):
        if not rule.get("pattern"):
            _block(f"{label} — rule {rule.get('name', '?')!r} has empty pattern")
            continue
        try:
            if re.search(rule["pattern"], cmd):
                _block(_message(label, rule))
        except re.error as e:
            _block(f"{label} — rule {rule.get('name', '?')!r} has invalid regex: {e}")

    for rule in rules.get("ask", []):
        if not rule.get("pattern"):
            _block(f"{label} — rule {rule.get('name', '?')!r} has empty pattern")
            continue
        try:
            if re.search(rule["pattern"], cmd):
                exc = rule.get("except")
                if exc:
                    try:
                        if re.search(exc, cmd):
                            continue
                    except re.error as e:
                        _block(f"{label} — rule {rule.get('name', '?')!r} has invalid 'except' regex: {e}")
                        continue
                asks.append(_message(label, rule))
        except re.error as e:
            _block(f"{label} — rule {rule.get('name', '?')!r} has invalid regex: {e}")

    return blocks, asks


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        sys.exit(0)

    if data.get("tool_name") != "Bash":
        sys.exit(0)

    cmd = data.get("tool_input", {}).get("command", "")
    if not cmd:
        sys.exit(0)

    # Determine rules path(s): single file or directory
    if len(sys.argv) > 1:
        target = sys.argv[1]
    else:
        target = os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "rules")

    if os.path.isdir(target):
        rule_files = sorted(glob.glob(os.path.join(target, "*.yml")))
    elif os.path.isfile(target):
        rule_files = [target]
    else:
        print(json.dumps({"decision": "block", "reason": f"watchdog: rules not found: {target}"}, separators=(",", ":")))
        sys.exit(0)

    all_blocks = []
    all_asks = []

    for rule_file in rule_files:
        try:
            config = parse_rules_yml(rule_file)
        except Exception as e:
            all_blocks.append(f"watchdog: failed to load rules: {e}")
            continue
        blocks, asks = evaluate_rules(config, cmd)
        all_blocks.extend(blocks)
        all_asks.extend(asks)

    if all_blocks:
        print(json.dumps({"decision": "block", "reason": "\n".join(all_blocks)}, separators=(",", ":")))
    elif all_asks:
        print(json.dumps({"decision": "ask", "message": "\n".join(all_asks)}, separators=(",", ":")))

    sys.exit(0)


if __name__ == "__main__":
    main()
