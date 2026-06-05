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

Each decision is appended as a JSONL record to ~/.claude/claudewatch/decisions.jsonl
by default — the side channel the /ClaudeWatch:learn workflow reads. Set
CLAUDEWATCH_LOG to a path to log elsewhere, or to "off" (also 0/false/none/empty)
to disable it. Logging never affects the decision itself.

The ask-prompt reason reads `<rule>: <reason>`, where the reason prose is a
clickable OSC 8 terminal hyperlink to the rule's `ref` — so the verbose URL
stays out of the line. Set CLAUDEWATCH_HYPERLINKS to "off" (also
0/false/none/empty) to keep the plain `— <url>` form instead. Deny messages
always use the plain `— <url>` form: Claude Code renders them through its error
path, which strips OSC 8 without linking it. Deny messages also append the
`[plugin:ClaudeWatch]` source tag that Claude Code shows on ask prompts but
omits on deny errors. The logged reasons stay plain text regardless — no tag.
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


def _violation(rule):
    """A matched violation as structured data.

    `prefix` is the rule's `name` (the rule-set name is redundant once the
    reason links to the ref, so it's dropped); `reason` is the human prose;
    `ref` is the doc URL (or "" when absent). Keeping them apart lets the
    prompt make the *prose* the hyperlink while the log stays plain
    (`_message_plain`).
    """
    return {"prefix": rule.get("name") or "", "reason": rule["reason"], "ref": rule.get("ref") or ""}


def _error_violation(text):
    """A configuration/load error surfaced as a deny: no prefix, no ref."""
    return {"prefix": "", "reason": text, "ref": ""}


def _message_plain(v):
    """Canonical one-line message: `<prefix>: <reason>[ — <ref>]`.

    This is what gets written to the decision log, so the `/ClaudeWatch:learn`
    side channel always reads plain text — never escape sequences.
    """
    head = f"{v['prefix']}: {v['reason']}" if v["prefix"] else v["reason"]
    return f"{head} — {v['ref']}" if v["ref"] else head


_OSC8 = "\x1b]8;;"
_ST = "\x1b\\"

# Source attribution Claude Code shows on ask prompts but omits on deny errors;
# appended to deny reasons so the user always sees which plugin made the call.
_PLUGIN_TAG = "[plugin:ClaudeWatch]"


def _hyperlink(url, text):
    """Wrap `text` in an OSC 8 terminal hyperlink pointing at `url`."""
    return f"{_OSC8}{url}{_ST}{text}{_OSC8}{_ST}"


_HYPERLINKS_OFF_VALUES = frozenset(("off", "0", "false", "none", ""))


def _hyperlinks_enabled():
    """Whether the displayed reason renders refs as terminal hyperlinks.

    On by default. Set CLAUDEWATCH_HYPERLINKS to off/0/false/none/empty
    (case-insensitive) to fall back to the plain `— <url>` form — for
    terminals without OSC 8 support or anyone who prefers the bare URL.
    """
    raw = os.environ.get("CLAUDEWATCH_HYPERLINKS")
    if raw is None:
        return True
    return raw.strip().lower() not in _HYPERLINKS_OFF_VALUES


def _message_display(v, hyperlinks):
    """The reason line shown in the permission prompt.

    With hyperlinks on and a ref present, the reason prose itself becomes the
    clickable link to the ref — so it reads `<prefix>: <prose>` with the prose
    clickable — keeping the verbose URL out of the line. Otherwise it matches
    the plain log form.
    """
    if hyperlinks and v["ref"]:
        linked = _hyperlink(v["ref"], v["reason"])
        return f"{v['prefix']}: {linked}" if v["prefix"] else linked
    return _message_plain(v)


def _rule_target(rule):
    return rule.get("target") or "bash"


def evaluate_rules(config, input_kind, input_text, file_extension=None):
    """Evaluate a single rule set against an input.

    input_kind is "bash" or "file-content". input_text is the string to match
    against. file_extension is the lowercase extension (including the dot) of
    the target file, used to filter rule sets for file-content inputs.

    Returns (blocks, asks) — lists of violation dicts (see `_violation`).
    """
    blocks = []
    asks = []
    label = config.get("name") or "unknown"

    def _block(reason):
        blocks.append(_error_violation(reason))

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
                blocks.append(_violation(rule))
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
                asks.append(_violation(rule))
        except re.error as e:
            _block(f"{label} — rule {rule.get('name', '?')!r} has invalid regex: {e}")

    return blocks, asks


DEFAULT_LOG_PATH = "~/.claude/claudewatch/decisions.jsonl"
_LOG_OFF_VALUES = frozenset(("", "off", "0", "false", "none"))
_LOG_DEFAULT_VALUES = frozenset(("1", "true", "on", "yes"))


def _log_event(data, input_kind, input_text, decision, matched):
    """Append a decision record to the log unless logging is disabled.

    The side channel the `/ClaudeWatch:learn` workflow reads. It never
    influences the decision (which stays a pure function of command + rules)
    and never changes the exit code. A log-write failure is reported to stderr
    and swallowed so the hook still returns its decision.

    Destination resolution (case-insensitive) of CLAUDEWATCH_LOG:
      - unset, "1"/"true"/"on"/"yes" -> default path ~/.claude/claudewatch/decisions.jsonl
      - "off"/"0"/"false"/"none"/"" -> logging disabled (this is the opt-out)
      - anything else -> treated as the destination path
    """
    raw = os.environ.get("CLAUDEWATCH_LOG")
    if raw is None:
        dest = DEFAULT_LOG_PATH
    else:
        token = raw.strip().lower()
        if token in _LOG_OFF_VALUES:
            return
        dest = DEFAULT_LOG_PATH if token in _LOG_DEFAULT_VALUES else raw
    dest = os.path.expanduser(dest)

    from datetime import datetime, timezone

    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "session": data.get("session_id"),
        "cwd": data.get("cwd"),
        "tool": data.get("tool_name"),
        "mode": data.get("permission_mode"),
        "decision": decision,
        "matched": matched,
    }
    if input_kind == "bash":
        entry["command"] = input_text
    else:
        tool_input = data.get("tool_input", {}) or {}
        entry["path"] = tool_input.get("file_path")

    try:
        parent = os.path.dirname(dest)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(dest, "a") as f:
            f.write(json.dumps(entry, separators=(",", ":")) + "\n")
    except OSError as e:
        print(f"watchdog: failed to write decision log to {dest}: {e}", file=sys.stderr)


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
            all_blocks.append(_error_violation(f"watchdog: failed to load rules: {e}"))
            continue
        blocks, asks = evaluate_rules(config, input_kind, input_text, file_extension)
        all_blocks.extend(blocks)
        all_asks.extend(asks)

    if all_blocks:
        decision, chosen = "deny", all_blocks
    elif all_asks:
        decision, chosen = "ask", all_asks
    else:
        decision, chosen = "allow", []

    # Log the canonical plain text; render hyperlinks only in the prompt.
    _log_event(data, input_kind, input_text, decision, [_message_plain(v) for v in chosen])

    if decision != "allow":
        # Only the ask prompt renders OSC 8: Claude Code's error renderer (the
        # deny path) strips the escape without making it clickable, which would
        # drop the ref entirely. So deny keeps the plain `— <url>` form.
        hyperlinks = decision == "ask" and _hyperlinks_enabled()
        reason = "\n".join(_message_display(v, hyperlinks) for v in chosen)
        # Claude Code tags ask prompts with the source plugin but leaves deny
        # errors unattributed, so append the tag ourselves on the deny path to
        # match — the user should always see which plugin made the call.
        if decision == "deny":
            reason += f" {_PLUGIN_TAG}"
        _emit(decision, reason)

    sys.exit(0)


if __name__ == "__main__":
    main()
