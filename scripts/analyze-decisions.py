#!/usr/bin/env python3
"""
analyze-decisions: turn a ClaudeWatch decision log into review proposals.

Reads the JSONL written by watchdog.py (on by default unless CLAUDEWATCH_LOG is
off), groups records by command shape, cross-references the current Claude Code allow list,
and emits a structured proposal the /ClaudeWatch:learn skill renders for
batch approval.

Three buckets:
  - allow_candidates  — commands ClaudeWatch allows that are NOT covered by an
                        allow rule in settings.json, so Claude Code prompts on
                        them. Promoting these to the allow list removes prompts.
  - except_candidates — commands ClaudeWatch repeatedly asks about. Candidates
                        for an `except` (if a safe variant) or for acceptance.
  - deny_summary      — commands ClaudeWatch blocked, grouped by reason.
                        Informational: a high count may mean a workflow you
                        need is blocked.

Read-only, stdlib-only, no network. The allow-pattern match is an approximate
coverage check (Claude Code's own matcher is the source of truth); it exists only
to avoid re-proposing commands you already allow.
"""

import argparse
import glob
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

# `command_shape` is defined in the engine (it writes the shape to the log per
# [LOG-03]); the analyzer imports it so the reducer has one definition. Applying
# it to an already-logged shape is idempotent, so it also re-derives the allow
# pattern from a logged shape and reduces any legacy raw-command records.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from watchdog import command_shape  # noqa: E402


DEFAULT_LOG = "~/.claude/claudewatch/decisions.jsonl"
DEFAULT_SETTINGS = "~/.claude/settings.json"

DURATION_UNITS = {"m": "minutes", "h": "hours", "d": "days", "w": "weeks"}


def parse_duration(text):
    """Parse '90m', '2h', '1d', '1w' into a timedelta."""
    m = re.fullmatch(r"(\d+)\s*([mhdw])", text.strip())
    if not m:
        raise ValueError(f"invalid duration {text!r} (use forms like 90m, 2h, 1d, 1w)")
    return timedelta(**{DURATION_UNITS[m.group(2)]: int(m.group(1))})


def load_allow_patterns(settings_path):
    """Return a list of (tool, literal, open_ended) from settings.json allow rules.

    Reduces `Bash(git push:*)` / `Monitor(cat *)` to the literal a shape must
    lead with, and a wildcard-free `Bash(git push)` to one it must equal. The
    tool is carried through because the two rule families are separate: a
    `Bash(…)` rule does not cover the same command via `Monitor`.
    """
    path = os.path.expanduser(settings_path)
    if not os.path.isfile(path):
        return []
    with open(path) as f:
        settings = json.load(f)
    patterns = []
    for rule in settings.get("permissions", {}).get("allow", []):
        m = re.fullmatch(r"(Bash|Monitor)\((.*)\)", rule)
        if not m:
            continue
        head, wildcard, tail = m.group(2).strip().partition("*")
        # Pattern text after the wildcard (`Bash(git * main)`) constrains tokens
        # the shape has already dropped, so nothing here can be compared against
        # it. Contributing no literal errs toward proposing, per [SK-14].
        if tail.strip():
            continue
        patterns.append((m.group(1), head.rstrip().rstrip(": "), bool(wildcard)))
    return patterns


def is_already_allowed(tool, shape, allow_patterns):
    """True when an allow rule already covers this command shape.

    `Bash(git:*)` covers `git status` and leaves `gitk` alone — a different
    program the rule never named.
    """
    for rule_tool, literal, open_ended in allow_patterns:
        if rule_tool != tool or not literal:
            continue
        if shape == literal or (open_ended and shape.startswith(literal + " ")):
            return True
    return False


def read_records(log_path, cutoff):
    """Yield decision records from the log, optionally filtered to ts >= cutoff."""
    path = os.path.expanduser(log_path)
    if not os.path.isfile(path):
        raise FileNotFoundError(path)
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "schema" in rec and "decision" not in rec:
                continue  # the log's schema header ([LOG-06]), not a decision record
            if cutoff is not None:
                ts = rec.get("ts")
                if ts:
                    try:
                        when = datetime.fromisoformat(ts)
                    except ValueError:
                        when = None
                    if when is not None and when < cutoff:
                        continue
            yield rec


def summarize_window(records):
    """Describe the slice of history the proposals are drawn from.

    Returns the distinct-session count and the oldest/newest timestamps with
    the span between them in days, so the skill can state how much history
    backs its suggestions (SK-18). Records without a parseable `ts` contribute
    to the session count but not the span.
    """
    sessions = {rec.get("session") for rec in records if rec.get("session")}
    timestamps = []
    for rec in records:
        ts = rec.get("ts")
        if not ts:
            continue
        try:
            timestamps.append(datetime.fromisoformat(ts))
        except ValueError:
            continue
    oldest = min(timestamps) if timestamps else None
    newest = max(timestamps) if timestamps else None
    span_days = round((newest - oldest).total_seconds() / 86400, 2) if oldest else None
    return {
        "distinct_sessions": len(sessions),
        "oldest_ts": oldest.isoformat() if oldest else None,
        "newest_ts": newest.isoformat() if newest else None,
        "span_days": span_days,
    }


def analyze(records, allow_patterns, min_count, max_samples):
    allow_groups = defaultdict(lambda: {"count": 0, "samples": [], "cwds": set(), "pattern": None, "auto": 0})
    ask_groups = defaultdict(lambda: {"count": 0, "samples": [], "reasons": set()})
    deny_groups = defaultdict(lambda: {"count": 0, "samples": []})
    by_mode = defaultdict(int)

    for rec in records:
        by_mode[rec.get("mode") or "unspecified"] += 1
        decision = rec.get("decision")
        # Current records log the shape directly ([LOG-03]); legacy records (from
        # before that change) carry a raw `command`. Reduce either to a shape, so
        # the analyzer never surfaces a raw command — even out of an old log.
        src = rec.get("command_shape") or rec.get("command")
        if not src:
            continue  # file-content (Write/Edit) records have no command to group
        # Bash and Monitor both carry shell commands, but their host permission
        # rules are separate families, so an allow candidate is grouped and
        # proposed per tool. Legacy records predate the Monitor matcher.
        tool = rec.get("tool") or "Bash"
        shape, pattern = command_shape(src, tool)

        if decision == "allow":
            # Suppress on the shape, not the raw src: grouping keys on the shape
            # (which drops leading VAR=value/sudo), so the already-allowed check
            # must too — else a command like `FOO=1 echo …` shapes to `echo` but
            # its raw form doesn't start with the `echo` prefix and gets wrongly
            # re-proposed despite `Bash(echo *)` already allowing it.
            if is_already_allowed(tool, shape, allow_patterns):
                continue
            g = allow_groups[(tool, shape)]
            g["count"] += 1
            g["pattern"] = pattern
            if rec.get("mode") == "auto":
                g["auto"] += 1
            if rec.get("cwd"):
                g["cwds"].add(rec["cwd"])
            if len(g["samples"]) < max_samples and shape not in g["samples"]:
                g["samples"].append(shape)
        elif decision == "ask":
            g = ask_groups[shape]
            g["count"] += 1
            for reason in rec.get("matched", []):
                g["reasons"].add(reason)
            if len(g["samples"]) < max_samples and shape not in g["samples"]:
                g["samples"].append(shape)
        elif decision == "deny":
            for reason in rec.get("matched", []) or ["(unattributed)"]:
                g = deny_groups[reason]
                g["count"] += 1
                if len(g["samples"]) < max_samples and shape not in g["samples"]:
                    g["samples"].append(shape)

    allow_candidates = [
        {"tool": tool, "shape": shape, "suggested_allow": g["pattern"], "count": g["count"],
         "auto_executed": g["auto"], "distinct_dirs": len(g["cwds"]), "samples": g["samples"]}
        for (tool, shape), g in allow_groups.items() if g["count"] >= min_count
    ]
    except_candidates = [
        {"shape": shape, "count": g["count"], "reasons": sorted(g["reasons"]),
         "samples": g["samples"]}
        for shape, g in ask_groups.items() if g["count"] >= min_count
    ]
    deny_summary = [
        {"reason": reason, "count": g["count"], "samples": g["samples"]}
        for reason, g in deny_groups.items()
    ]

    allow_candidates.sort(key=lambda x: (-x["count"], x["tool"], x["shape"]))
    except_candidates.sort(key=lambda x: (-x["count"], x["shape"]))
    deny_summary.sort(key=lambda x: (-x["count"], x["reason"]))

    return {
        "allow_candidates": allow_candidates,
        "except_candidates": except_candidates,
        "deny_summary": deny_summary,
        "by_mode": dict(by_mode),
    }


def main():
    parser = argparse.ArgumentParser(description="Analyze a ClaudeWatch decision log.")
    parser.add_argument("--log", default=os.environ.get("CLAUDEWATCH_LOG"),
                        help="path to decisions.jsonl (default: resolved from $CLAUDEWATCH_LOG, "
                             f"else {DEFAULT_LOG})")
    parser.add_argument("--settings", default=DEFAULT_SETTINGS,
                        help="path to settings.json for the current allow list")
    parser.add_argument("--since", default=None,
                        help="only consider records newer than this (e.g. 1h, 1d, 1w)")
    parser.add_argument("--min-count", type=int, default=3,
                        help="minimum occurrences for a command to be proposed (default: 3)")
    parser.add_argument("--max-samples", type=int, default=5,
                        help="max sample commands kept per group (default: 5)")
    args = parser.parse_args()

    # Resolve the log path the same way the engine does (watchdog.py _log_event):
    # unset or an "on" token -> default path; an "off" token -> still look at the
    # default path so the not-found guidance can explain that logging is disabled.
    logging_disabled = False
    if args.log is None:
        args.log = DEFAULT_LOG
    else:
        token = args.log.strip().lower()
        if token in ("", "off", "0", "false", "none"):
            logging_disabled = True
            args.log = DEFAULT_LOG
        elif token in ("1", "true", "on", "yes"):
            args.log = DEFAULT_LOG

    cutoff = None
    if args.since:
        try:
            cutoff = datetime.now(timezone.utc) - parse_duration(args.since)
        except ValueError as e:
            print(f"analyze-decisions: {e}", file=sys.stderr)
            sys.exit(2)

    try:
        records = list(read_records(args.log, cutoff))
    except FileNotFoundError:
        if logging_disabled:
            print(
                "analyze-decisions: logging is disabled (CLAUDEWATCH_LOG is set to off).\n"
                "Decision logging is on by default; remove the off setting from the hook\n"
                "environment in settings.json to re-enable it, then run some sessions.",
                file=sys.stderr,
            )
        else:
            print(
                f"analyze-decisions: no decision log at {os.path.expanduser(args.log)} yet.\n"
                "Logging is on by default; this usually means no sessions have run with the\n"
                "ClaudeWatch hook active. Run some sessions, then review.",
                file=sys.stderr,
            )
        sys.exit(2)

    allow_patterns = load_allow_patterns(args.settings)
    result = analyze(records, allow_patterns, args.min_count, args.max_samples)
    result["meta"] = {
        "log": os.path.expanduser(args.log),
        "records_considered": len(records),
        "since": args.since,
        "min_count": args.min_count,
        **summarize_window(records),
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
