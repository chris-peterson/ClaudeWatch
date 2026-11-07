#!/usr/bin/env python3
"""
overrides: read and write the user's rule overrides ([OVR-01]–[OVR-07]).

The shipped rule sets in `watches/` are replaced on every plugin upgrade, so a
user's changes live in ~/.claude/claudewatch/overrides.yml instead, and this is
the one program that writes it. /ClaudeWatch:rules and /ClaudeWatch:learn both
go through it.

  overrides.py show [--json]              shipped and effective tier of every rule
  overrides.py set <set> off              turn a rule set off
  overrides.py set <set> <rule> <tier>    tier is ask, block, or off
  overrides.py reset [<set> [<rule>]]     remove overrides (all, a set's, or one)
  overrides.py check                      load the file the way the engine does
  overrides.py session-start              SessionStart hook: log what differs

Stdlib-only, no network.
"""

import glob
import json
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from watchdog import (  # noqa: E402
    OVERRIDE_TIERS,
    OVERRIDES_PATH,
    OverridesError,
    append_log_record,
    load_overrides,
    override_report,
    parse_rules_yml,
)

PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WATCHES = os.path.join(PLUGIN_ROOT, "watches")
HEADER = "# ClaudeWatch rule overrides, written by scripts/overrides.py. Tiers: ask, block, off.\n"


def shipped_configs():
    return [parse_rules_yml(path) for path in sorted(glob.glob(os.path.join(WATCHES, "*.yml")))]


def plugin_version():
    try:
        with open(os.path.join(PLUGIN_ROOT, ".claude-plugin", "plugin.json")) as f:
            return json.load(f).get("version")
    except (OSError, ValueError):
        return None


def _quote(name):
    if any(c in name for c in ":#'\"") or name != name.strip():
        return "'" + name.replace("'", "''") + "'"
    return name


def write_overrides(overrides):
    path = os.path.expanduser(OVERRIDES_PATH)
    if not overrides:
        if os.path.exists(path):
            os.remove(path)
        return
    lines = [HEADER]
    for set_name in sorted(overrides):
        entry = overrides[set_name]
        if entry == "off":
            lines.append(f"{_quote(set_name)}: off\n")
        elif entry:
            lines.append(f"{_quote(set_name)}:\n")
            lines.extend(f"  {_quote(rule)}: {tier}\n" for rule, tier in sorted(entry.items()))
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)


def show(configs, overrides):
    report = override_report(configs, overrides)
    sets = []
    for config in configs:
        name = config.get("name")
        entry = overrides.get(name)
        rules = []
        for tier in ("block", "ask"):
            for rule in config.get("rules", {}).get(tier, []):
                effective = tier if entry in (None, "off") else entry.get(rule.get("name"), tier)
                rules.append({"name": rule.get("name"), "shipped": tier, "effective": effective,
                              "reason": rule.get("reason")})
        sets.append({"set": name, "off": entry == "off", "rules": rules})
    return {"overrides_file": os.path.expanduser(OVERRIDES_PATH), "sets": sets, "stale": report["stale"]}


def cmd_set(configs, overrides, args):
    shipped = {c.get("name"): c for c in configs}
    if len(args) == 2 and args[1] == "off":
        set_name = args[0]
        if set_name not in shipped:
            return f"no shipped rule set named {set_name!r}"
        overrides[set_name] = "off"
    elif len(args) == 3:
        set_name, rule_name, tier = args
        if set_name not in shipped:
            return f"no shipped rule set named {set_name!r}"
        if tier not in OVERRIDE_TIERS:
            return f"tier must be one of {', '.join(OVERRIDE_TIERS)}, not {tier!r}"
        tiers = {rule.get("name"): t for t in ("block", "ask") for rule in shipped[set_name]["rules"][t]}
        if rule_name not in tiers:
            return f"rule set {set_name!r} has no rule named {rule_name!r}"
        entry = overrides.get(set_name)
        entry = {} if entry in (None, "off") else entry
        if tier == tiers[rule_name]:
            entry.pop(rule_name, None)
        else:
            entry[rule_name] = tier
        if entry:
            overrides[set_name] = entry
        else:
            overrides.pop(set_name, None)
    else:
        return "usage: overrides.py set <set> off | set <set> <rule> <ask|block|off>"
    write_overrides(overrides)
    return None


def cmd_reset(overrides, args):
    if not args:
        overrides.clear()
    elif len(args) == 1:
        overrides.pop(args[0], None)
    elif len(args) == 2:
        entry = overrides.get(args[0])
        if isinstance(entry, dict):
            entry.pop(args[1], None)
            if not entry:
                overrides.pop(args[0])
    else:
        return "usage: overrides.py reset [<set> [<rule>]]"
    write_overrides(overrides)
    return None


def session_start():
    """Log what the overrides change, and warn in context when they are broken ([OVR-06])."""
    try:
        event = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        event = {}
    record = {"ts": datetime.now(timezone.utc).isoformat(), "event": "session_start",
              "session": event.get("session_id") if isinstance(event, dict) else None,
              "plugin_version": plugin_version()}
    try:
        overrides = load_overrides()
    except OverridesError as e:
        append_log_record({**record, "overrides_error": str(e)})
        print(f"ClaudeWatch: the rule overrides file is unreadable, so every screened command and "
              f"file write will be denied until it is fixed or removed: {e}")
        return
    if not overrides:
        return
    report = override_report(shipped_configs(), overrides)
    if not any(report.values()):
        return
    append_log_record({**record, **report})
    if report["stale"]:
        names = ", ".join(s["set"] + (f" / {s['rule']}" if "rule" in s else "") for s in report["stale"])
        print(f"ClaudeWatch: these rule overrides name rules the shipped rule sets no longer have, "
              f"and are ignored: {names}. Run /ClaudeWatch:rules to review them.")


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    command, rest = args[0], args[1:]
    if command == "session-start":
        session_start()
        return 0
    try:
        overrides = load_overrides()
    except OverridesError as e:
        print(f"overrides: {e}", file=sys.stderr)
        return 1
    if command == "check":
        print(f"overrides: {os.path.expanduser(OVERRIDES_PATH)} is valid "
              f"({len(overrides)} rule set{'s' if len(overrides) != 1 else ''} overridden)")
        return 0
    configs = shipped_configs()
    if command == "show":
        result = show(configs, overrides)
        if "--json" in rest:
            print(json.dumps(result, indent=2))
        else:
            for s in result["sets"]:
                print(f"{s['set']}{'  (off)' if s['off'] else ''}")
                for r in s["rules"]:
                    mark = "" if r["effective"] == r["shipped"] and not s["off"] else f"  <- {r['shipped']}"
                    print(f"  {('off' if s['off'] else r['effective']):5}  {r['name']}{mark}")
            for st in result["stale"]:
                print(f"stale: {st['set']}" + (f" / {st['rule']}" if "rule" in st else ""))
        return 0
    if command == "set":
        error = cmd_set(configs, overrides, rest)
    elif command == "reset":
        error = cmd_reset(overrides, rest)
    else:
        error = f"unknown command {command!r}"
    if error:
        print(f"overrides: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
