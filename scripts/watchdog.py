#!/usr/bin/env python3
"""
claude-watchdog: PreToolUse hook for Claude Code

Generic rule engine that enforces safety rules loaded from YAML config files.
Reads tool input JSON from stdin, evaluates all rule sets in a directory,
and outputs a single coalesced JSON decision to stdout.

Supports three tool inputs:
- Bash: matches against tool_input.command (target: bash rules)
- Write: matches against tool_input.content (target: file-content rules)
- Edit: matches against the full post-edit file content reconstructed from
  the on-disk file plus tool_input.old_string -> tool_input.new_string
  substitution (target: file-content rules)
"""

import glob
import json
import os
import re
import sys


VALID_TARGETS = ("bash", "file-content")


def _unquote(s):
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1].replace("''", "'")
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s


def _parse_inline_list(val):
    """Parse YAML inline list syntax like ['.ps1', '.psm1'] or [.ps1, .psm1]."""
    val = val.strip()
    if not (val.startswith("[") and val.endswith("]")):
        return []
    inner = val[1:-1].strip()
    if not inner:
        return []
    return [_unquote(item.strip()) for item in inner.split(",") if item.strip()]


def parse_rules_yml(path):
    """Parse a watchdog rules YAML file without external dependencies.

    Handles the format:
      name: watch-name
      filter: 'optional-regex'           # bash-target only
      extensions: ['.ps1', '.psm1']      # file-content-target only
      rules:
        block:
          - name: ...
            pattern: '...'
            target: bash | file-content  # optional, default bash
            reason: ...
            ref: ...
        ask:
          - name: ...
            pattern: '...'
            target: bash | file-content  # optional, default bash
            reason: ...
            ref: ...
    """
    result = {
        "name": "",
        "filter": "",
        "extensions": [],
        "rules": {"block": [], "ask": []},
    }
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
            elif indent == 0 and stripped.startswith("extensions:"):
                result["extensions"] = _parse_inline_list(stripped[11:].strip())
            elif indent == 0 and stripped == "rules:":
                pass

            # section headers (indent 2)
            elif indent == 2 and stripped in ("block:", "ask:"):
                current_section = stripped[:-1]
                current_item = None

            # list item start (indent 4)
            elif indent == 4 and stripped.startswith("- name:") and current_section is not None:
                current_item = {"name": _unquote(stripped[7:].strip()), "pattern": "", "reason": "", "ref": "", "target": "bash"}
                result["rules"][current_section].append(current_item)

            elif indent == 4 and stripped.startswith("- pattern:") and current_section is not None:
                current_item = {"name": "", "pattern": _unquote(stripped[10:].strip()), "reason": "", "ref": "", "target": "bash"}
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

            elif indent == 6 and stripped.startswith("target:") and current_item is not None:
                current_item["target"] = _unquote(stripped[7:].strip())

            elif indent == 6 and stripped.startswith("except:") and current_item is not None:
                if current_section == "block":
                    print(f"warning: {result['name'] or path} — rule {current_item.get('name', '?')!r} has 'except' on a block rule (ignored — except only applies to ask rules)", file=sys.stderr)
                else:
                    current_item["except"] = _unquote(stripped[7:].strip())

            else:
                # Unrecognized line — warn so typos surface instead of silently disappearing.
                label = result["name"] or path
                where = ""
                if indent == 0:
                    where = "top-level"
                elif indent == 2:
                    where = "section header"
                elif indent == 4:
                    where = "list item"
                elif indent == 6:
                    rule_name = current_item.get("name", "?") if current_item else "?"
                    where = f"rule {rule_name!r}"
                else:
                    where = f"indent {indent}"
                print(f"warning: {label} — unrecognized line in {where}: {stripped!r}", file=sys.stderr)

    return result


def _message(label, rule):
    parts = [label, rule["reason"]]
    if rule.get("ref"):
        parts.append(rule["ref"])
    return " — ".join(parts)


def _rule_target(rule):
    return rule.get("target") or "bash"


def evaluate_rules(config, input_kind, input_text, file_extension=None):
    """Evaluate a single rule set against an input.

    input_kind is "bash" or "file-content". input_text is the string to match
    against. file_extension is the lowercase extension (including the dot) of
    the target file, used to filter rule sets for file-content inputs.

    Returns (blocks, asks) — lists of violation message strings.
    """
    blocks = []
    asks = []
    label = config.get("name") or "unknown"

    def _block(reason):
        blocks.append(reason)

    if input_kind == "bash":
        filt = config.get("filter")
        if filt:
            try:
                if not re.search(filt, input_text):
                    return blocks, asks
            except re.error as e:
                _block(f"{label} — invalid filter regex: {e}")
                return blocks, asks
    else:  # file-content
        extensions = config.get("extensions") or []
        if not extensions:
            return blocks, asks
        if file_extension is None or file_extension.lower() not in [e.lower() for e in extensions]:
            return blocks, asks

    rules = config.get("rules", {})

    for rule in rules.get("block", []):
        target = _rule_target(rule)
        if target not in VALID_TARGETS:
            _block(f"{label} — rule {rule.get('name', '?')!r} has invalid target {target!r}")
            continue
        if target != input_kind:
            continue
        if not rule.get("pattern"):
            _block(f"{label} — rule {rule.get('name', '?')!r} has empty pattern")
            continue
        try:
            if re.search(rule["pattern"], input_text):
                _block(_message(label, rule))
        except re.error as e:
            _block(f"{label} — rule {rule.get('name', '?')!r} has invalid regex: {e}")

    for rule in rules.get("ask", []):
        target = _rule_target(rule)
        if target not in VALID_TARGETS:
            _block(f"{label} — rule {rule.get('name', '?')!r} has invalid target {target!r}")
            continue
        if target != input_kind:
            continue
        if not rule.get("pattern"):
            _block(f"{label} — rule {rule.get('name', '?')!r} has empty pattern")
            continue
        try:
            if re.search(rule["pattern"], input_text):
                exc = rule.get("except")
                if exc:
                    try:
                        if re.search(exc, input_text):
                            continue
                    except re.error as e:
                        _block(f"{label} — rule {rule.get('name', '?')!r} has invalid 'except' regex: {e}")
                        continue
                asks.append(_message(label, rule))
        except re.error as e:
            _block(f"{label} — rule {rule.get('name', '?')!r} has invalid regex: {e}")

    return blocks, asks


def _resolve_input(data):
    """Map tool_input -> (input_kind, input_text, file_extension) or None."""
    tool_name = data.get("tool_name")
    tool_input = data.get("tool_input", {}) or {}

    if tool_name == "Bash":
        cmd = tool_input.get("command", "")
        if not cmd:
            return None
        return "bash", cmd, None

    if tool_name == "Write":
        content = tool_input.get("content", "")
        path = tool_input.get("file_path", "") or ""
        if not content:
            return None
        return "file-content", content, os.path.splitext(path)[1]

    if tool_name == "Edit":
        path = tool_input.get("file_path", "") or ""
        old_string = tool_input.get("old_string", "")
        new_string = tool_input.get("new_string", "")
        replace_all = bool(tool_input.get("replace_all", False))
        if not new_string and not old_string:
            return None
        try:
            with open(path) as f:
                existing = f.read()
            if replace_all:
                content = existing.replace(old_string, new_string)
            else:
                content = existing.replace(old_string, new_string, 1)
        except (OSError, FileNotFoundError):
            content = new_string
        if not content:
            return None
        return "file-content", content, os.path.splitext(path)[1]

    return None


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"watchdog: invalid JSON on stdin: {e}", file=sys.stderr)
        sys.exit(0)

    resolved = _resolve_input(data)
    if resolved is None:
        sys.exit(0)
    input_kind, input_text, file_extension = resolved

    if len(sys.argv) > 1:
        target = sys.argv[1]
    else:
        target = os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "rules")

    def _emit(decision, reason):
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": reason,
            }
        }, separators=(",", ":")))

    if os.path.isdir(target):
        rule_files = sorted(glob.glob(os.path.join(target, "*.yml")))
    elif os.path.isfile(target):
        rule_files = [target]
    else:
        _emit("deny", f"watchdog: rules not found: {target}")
        sys.exit(0)

    all_blocks = []
    all_asks = []

    for rule_file in rule_files:
        try:
            config = parse_rules_yml(rule_file)
        except Exception as e:
            all_blocks.append(f"watchdog: failed to load rules: {e}")
            continue
        blocks, asks = evaluate_rules(config, input_kind, input_text, file_extension)
        all_blocks.extend(blocks)
        all_asks.extend(asks)

    if all_blocks:
        _emit("deny", "\n".join(all_blocks))
    elif all_asks:
        _emit("ask", "\n".join(all_asks))

    sys.exit(0)


if __name__ == "__main__":
    main()
