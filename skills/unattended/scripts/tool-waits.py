#!/usr/bin/env python3
"""List the tool calls in a Claude Code session that waited long for their result.

Usage: tool-waits.py <session-id | transcript.jsonl> [min_minutes]

Reads the session's transcript and its subagents' transcripts (`<session>/subagents/`),
pairs each tool call with its result, and prints every call that took at least
min_minutes (default 3). Background calls are skipped, since they return at once.
A call still waiting is listed as OPEN.

A long wait on a quick command (a `mv`, an Edit, a `git commit`) is a permission prompt
nobody answered. A long wait on a test run or a subagent is usually the work itself.
"""
import glob
import json
import os
import sys
from datetime import datetime

PROJECTS = os.path.expanduser("~/.claude/projects")


def transcript_for(arg):
    if arg.endswith(".jsonl"):
        return arg
    hits = glob.glob(os.path.join(PROJECTS, "*", arg + ".jsonl"))
    if not hits:
        sys.exit(f"no transcript for session {arg} under {PROJECTS}")
    return hits[0]


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def waits(path, min_s):
    calls, rows = {}, []
    for line in open(path):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        t = d.get("timestamp")
        content = (d.get("message") or {}).get("content")
        if not t or not isinstance(content, list):
            continue
        for c in content:
            if c.get("type") == "tool_use":
                inp = c.get("input") or {}
                shape = inp.get("command") or inp.get("file_path") or inp.get("skill") or inp.get("description") or ""
                calls[c["id"]] = (ts(t), c.get("name"), " ".join(str(shape).split())[:90],
                                  bool(inp.get("run_in_background")))
            elif c.get("type") == "tool_result" and c.get("tool_use_id") in calls:
                start, name, shape, bg = calls.pop(c["tool_use_id"])
                body = c.get("content")
                if isinstance(body, list):
                    body = " ".join(x.get("text", "") for x in body if isinstance(x, dict))
                wait = (ts(t) - start).total_seconds()
                if wait >= min_s and not bg:
                    rows.append((start, f"{wait / 60:7.1f} min", name, shape, " ".join(str(body or "").split())[:80]))
    for start, name, shape, bg in calls.values():
        if not bg:
            rows.append((start, "   OPEN   ", name, shape, "(no result yet)"))
    return sorted(rows)


main = transcript_for(sys.argv[1])
min_s = float(sys.argv[2]) * 60 if len(sys.argv) > 2 else 180
sub_dir = os.path.join(main[: -len(".jsonl")], "subagents")
paths = [main] + sorted(glob.glob(os.path.join(sub_dir, "*.jsonl")))
found = False
for path in paths:
    rows = waits(path, min_s)
    if not rows:
        continue
    found = True
    print(f"== {os.path.basename(path)}")
    for start, wait, name, shape, result in rows:
        print(f"{wait}  {start.astimezone():%m-%d %H:%M}  {name:10} {shape}")
        print(f"{'':31}-> {result}")
if not found:
    print(f"no tool call waited {min_s / 60:g} min or more")
