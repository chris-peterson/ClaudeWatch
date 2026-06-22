#!/usr/bin/env python3
"""
reset-decisions: clear the ClaudeWatch decision log so the next analysis
measures from a fresh baseline.

After `/ClaudeWatch:learn` proposals are applied (allow-list additions, rule
edits) the accumulated history would otherwise keep re-surfacing the same
already-dispositioned commands. Resetting starts the next window from the
post-change baseline (SK-19).

By default the log is **archived** — moved to `~/.claude/claudewatch/archive/`
beside the durable log — so prior history stays recoverable, matching the
project's "block is for no-recovery" ethos. `--hard` deletes it outright.

Resolves the log path the same way the engine does (watchdog.py _log_event):
  - unset, "1"/"true"/"on"/"yes"  -> default path
  - "off"/"0"/"false"/"none"/""   -> logging disabled (nothing to reset)
  - anything else                 -> treated as the destination path

Stdlib-only, no network.
"""

import argparse
import os
import sys
from datetime import datetime, timezone

DEFAULT_LOG = "~/.claude/claudewatch/decisions.jsonl"
_LOG_OFF_VALUES = {"", "off", "0", "false", "none"}
_LOG_DEFAULT_VALUES = {"1", "true", "on", "yes"}


def resolve_log(arg_log):
    """Return (path, disabled) mirroring the engine's CLAUDEWATCH_LOG handling."""
    raw = arg_log if arg_log is not None else os.environ.get("CLAUDEWATCH_LOG")
    if raw is None:
        return os.path.expanduser(DEFAULT_LOG), False
    token = raw.strip().lower()
    if token in _LOG_OFF_VALUES:
        return os.path.expanduser(DEFAULT_LOG), True
    if token in _LOG_DEFAULT_VALUES:
        return os.path.expanduser(DEFAULT_LOG), False
    return os.path.expanduser(raw), False


def summarize(path):
    """Count records and the oldest/newest timestamps in the log."""
    count = 0
    timestamps = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith('{"schema":'):
                continue  # the log's schema header ([LOG-06]), not a decision record
            count += 1
            # Cheap ts pull without a full JSON parse per line; the field is
            # always first in the record (watchdog writes it first).
            marker = '"ts":"'
            i = line.find(marker)
            if i == -1:
                continue
            i += len(marker)
            j = line.find('"', i)
            if j == -1:
                continue
            try:
                timestamps.append(datetime.fromisoformat(line[i:j]))
            except ValueError:
                continue
    oldest = min(timestamps) if timestamps else None
    newest = max(timestamps) if timestamps else None
    span_days = round((newest - oldest).total_seconds() / 86400, 2) if oldest else None
    return count, oldest, newest, span_days


def main():
    parser = argparse.ArgumentParser(description="Reset the ClaudeWatch decision log.")
    parser.add_argument("--log", default=None,
                        help="path to decisions.jsonl (default: resolved from "
                             f"$CLAUDEWATCH_LOG, else {DEFAULT_LOG})")
    parser.add_argument("--hard", action="store_true",
                        help="delete the log instead of archiving it (unrecoverable)")
    args = parser.parse_args()

    path, disabled = resolve_log(args.log)

    if disabled:
        print(
            "reset-decisions: logging is disabled (CLAUDEWATCH_LOG is set to off); "
            "there is no active log to reset.",
            file=sys.stderr,
        )
        sys.exit(2)

    if not os.path.isfile(path):
        print(f"reset-decisions: no decision log at {path}; nothing to reset.")
        sys.exit(0)

    count, oldest, newest, span_days = summarize(path)
    span = (f"{count} records across {span_days} days "
            f"({oldest.isoformat()} → {newest.isoformat()})") if oldest else f"{count} records"

    if args.hard:
        os.remove(path)
        print(f"reset-decisions: deleted decision log ({span}).")
        sys.exit(0)

    archive_dir = os.path.join(os.path.dirname(path), "archive")
    os.makedirs(archive_dir, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    dest = os.path.join(archive_dir, f"decisions-{stamp}.jsonl")
    os.rename(path, dest)
    print(f"reset-decisions: archived decision log ({span}) to {dest}.")
    sys.exit(0)


if __name__ == "__main__":
    main()
