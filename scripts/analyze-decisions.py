#!/usr/bin/env python3
"""
analyze-decisions: turn a ClaudeWatch decision log into review proposals.

Reads the JSONL written by watchdog.py (on by default unless CLAUDEWATCH_LOG is
off), groups records by command shape, and emits a structured proposal the
/ClaudeWatch:learn skill renders for batch approval.

Two buckets:
  - except_candidates — commands ClaudeWatch repeatedly asks about. Candidates
                        for an `except` (if a safe variant) or for acceptance.
  - deny_summary      — commands ClaudeWatch blocked, grouped by reason.
                        Informational: a high count may mean a workflow you
                        need is blocked.

Read-only, stdlib-only, no network.
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
# it to an already-logged shape is idempotent, so it also reduces any legacy
# raw-command records.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from watchdog import command_shape  # noqa: E402


DEFAULT_LOG = "~/.claude/claudewatch/decisions.jsonl"

DURATION_UNITS = {"m": "minutes", "h": "hours", "d": "days", "w": "weeks"}


def parse_duration(text):
    """Parse '90m', '2h', '1d', '1w' into a timedelta."""
    m = re.fullmatch(r"(\d+)\s*([mhdw])", text.strip())
    if not m:
        raise ValueError(f"invalid duration {text!r} (use forms like 90m, 2h, 1d, 1w)")
    return timedelta(**{DURATION_UNITS[m.group(2)]: int(m.group(1))})


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
            if "decision" not in rec:
                continue  # the schema header ([LOG-06]) or a session-start record ([OVR-06])
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


def analyze(records, min_count, max_samples):
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
        shape = command_shape(src)
        reasons = rec.get("matched") or []
        # Each reason is filed under the shape of the part of the command its
        # rule matched ([LOG-03]). A reason the engine added itself (the
        # compound escalation) has none, so it takes the first rule's; a
        # record from before `matched_shapes` takes the command's shape.
        logged = rec.get("matched_shapes") or []
        first = next((s for s in logged if s), shape)
        reason_shapes = [(r, (logged[i] if i < len(logged) else None) or first) for i, r in enumerate(reasons)]

        if decision == "ask":
            for part_shape in dict.fromkeys(s for _, s in reason_shapes) or [shape]:
                g = ask_groups[part_shape]
                g["count"] += 1
                g["reasons"].update(r for r, s in reason_shapes if s == part_shape)
                if len(g["samples"]) < max_samples and part_shape not in g["samples"]:
                    g["samples"].append(part_shape)
        elif decision == "deny":
            for reason, part_shape in reason_shapes or [("(unattributed)", shape)]:
                g = deny_groups[reason]
                g["count"] += 1
                if len(g["samples"]) < max_samples and part_shape not in g["samples"]:
                    g["samples"].append(part_shape)

    except_candidates = [
        {"shape": shape, "count": g["count"], "reasons": sorted(g["reasons"]),
         "samples": g["samples"]}
        for shape, g in ask_groups.items() if g["count"] >= min_count
    ]
    deny_summary = [
        {"reason": reason, "count": g["count"], "samples": g["samples"]}
        for reason, g in deny_groups.items()
    ]

    except_candidates.sort(key=lambda x: (-x["count"], x["shape"]))
    deny_summary.sort(key=lambda x: (-x["count"], x["reason"]))

    return {
        "except_candidates": except_candidates,
        "deny_summary": deny_summary,
        "by_mode": dict(by_mode),
    }


def main():
    parser = argparse.ArgumentParser(description="Analyze a ClaudeWatch decision log.")
    parser.add_argument("--log", default=os.environ.get("CLAUDEWATCH_LOG"),
                        help="path to decisions.jsonl (default: resolved from $CLAUDEWATCH_LOG, "
                             f"else {DEFAULT_LOG})")
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

    result = analyze(records, args.min_count, args.max_samples)
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
