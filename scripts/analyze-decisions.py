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
prefix check (Claude Code's own matcher is the source of truth); it exists only
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


DEFAULT_LOG = "~/.claude/claudewatch/decisions.jsonl"
DEFAULT_SETTINGS = "~/.claude/settings.json"

# Tools whose first argument is a subcommand worth keeping in the command shape,
# so `git push` and `git status` group separately rather than collapsing to `git`.
SUBCOMMAND_TOOLS = {
    "git", "gh", "glab", "npm", "npx", "yarn", "pnpm", "pip", "pip3", "cargo",
    "go", "docker", "kubectl", "just", "make", "brew", "terraform", "bundle",
    "rake", "dotnet", "aws", "gcloud", "az", "systemctl", "apt", "apt-get",
    "uv", "poetry", "deno", "bun",
}

DURATION_UNITS = {"m": "minutes", "h": "hours", "d": "days", "w": "weeks"}

# A subcommand token is a bare lowercase word (e.g. `pr`, `view`, `commit`).
# Stopping at the first flag, path, or value keeps shapes specific — so a
# suggested allow pattern stays as narrow as the commands actually run.
SUBCOMMAND_LIKE = re.compile(r"^[a-z][a-z0-9-]*$")
MAX_SHAPE_TOKENS = 4


def parse_duration(text):
    """Parse '90m', '2h', '1d', '1w' into a timedelta."""
    m = re.fullmatch(r"(\d+)\s*([mhdw])", text.strip())
    if not m:
        raise ValueError(f"invalid duration {text!r} (use forms like 90m, 2h, 1d, 1w)")
    return timedelta(**{DURATION_UNITS[m.group(2)]: int(m.group(1))})


def load_allow_prefixes(settings_path):
    """Return a list of (prefix, raw_pattern) from settings.json Bash allow rules.

    Converts `Bash(git push:*)` / `Bash(cat *)` into the literal prefix a command
    must start with to be considered already-allowed. This is an approximation of
    Claude Code's matcher, used only to suppress already-allowed suggestions.
    """
    path = os.path.expanduser(settings_path)
    if not os.path.isfile(path):
        return []
    with open(path) as f:
        settings = json.load(f)
    prefixes = []
    for rule in settings.get("permissions", {}).get("allow", []):
        m = re.fullmatch(r"Bash\((.*)\)", rule)
        if not m:
            continue
        inner = m.group(1)
        prefix = re.split(r":\*|\*", inner, maxsplit=1)[0].rstrip()
        prefixes.append((prefix, rule))
    return prefixes


def is_already_allowed(command, allow_prefixes):
    for prefix, _ in allow_prefixes:
        if prefix and command.startswith(prefix):
            return True
    return False


def command_shape(command):
    """Reduce a command to a stable grouping prefix and a suggested allow pattern.

    Skips leading `VAR=value` assignments and `sudo`, then keeps the program and
    (for known subcommand tools) the subcommand. Returns (shape, allow_pattern).
    """
    tokens = command.strip().split()
    i = 0
    while i < len(tokens) and (re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", tokens[i]) or tokens[i] == "sudo"):
        i += 1
    if i >= len(tokens):
        return command.strip(), f"Bash({command.strip()})"

    prog = os.path.basename(tokens[i])
    shape_tokens = [prog]
    if prog in SUBCOMMAND_TOOLS:
        j = i + 1
        while j < len(tokens) and len(shape_tokens) < MAX_SHAPE_TOKENS and SUBCOMMAND_LIKE.match(tokens[j]):
            shape_tokens.append(tokens[j])
            j += 1

    shape = " ".join(shape_tokens)
    return shape, f"Bash({shape}:*)"


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


def analyze(records, allow_prefixes, min_count, max_samples):
    allow_groups = defaultdict(lambda: {"count": 0, "samples": [], "cwds": set(), "pattern": None, "auto": 0})
    ask_groups = defaultdict(lambda: {"count": 0, "samples": [], "reasons": set()})
    deny_groups = defaultdict(lambda: {"count": 0, "samples": []})
    by_mode = defaultdict(int)

    for rec in records:
        by_mode[rec.get("mode") or "unspecified"] += 1
        decision = rec.get("decision")
        command = rec.get("command")
        if not command:
            continue  # file-content (Write/Edit) records have no command to group
        shape, pattern = command_shape(command)

        if decision == "allow":
            if is_already_allowed(command, allow_prefixes):
                continue
            g = allow_groups[shape]
            g["count"] += 1
            g["pattern"] = pattern
            if rec.get("mode") == "auto":
                g["auto"] += 1
            if rec.get("cwd"):
                g["cwds"].add(rec["cwd"])
            if len(g["samples"]) < max_samples and command not in g["samples"]:
                g["samples"].append(command)
        elif decision == "ask":
            g = ask_groups[shape]
            g["count"] += 1
            for reason in rec.get("matched", []):
                g["reasons"].add(reason)
            if len(g["samples"]) < max_samples and command not in g["samples"]:
                g["samples"].append(command)
        elif decision == "deny":
            for reason in rec.get("matched", []) or ["(unattributed)"]:
                g = deny_groups[reason]
                g["count"] += 1
                if len(g["samples"]) < max_samples and command not in g["samples"]:
                    g["samples"].append(command)

    allow_candidates = [
        {"shape": shape, "suggested_allow": g["pattern"], "count": g["count"],
         "auto_executed": g["auto"], "distinct_dirs": len(g["cwds"]), "samples": g["samples"]}
        for shape, g in allow_groups.items() if g["count"] >= min_count
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

    allow_candidates.sort(key=lambda x: (-x["count"], x["shape"]))
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

    allow_prefixes = load_allow_prefixes(args.settings)
    result = analyze(records, allow_prefixes, args.min_count, args.max_samples)
    result["meta"] = {
        "log": os.path.expanduser(args.log),
        "records_considered": len(records),
        "since": args.since,
        "min_count": args.min_count,
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
