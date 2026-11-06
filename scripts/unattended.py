#!/usr/bin/env python3
"""
unattended: keep a session marked unattended while the user is away ([SK-20]–[SK-23]).

Run as a hook, it reads one event from stdin:

  - UserPromptSubmit led by /ClaudeWatch:unattended or /unattended -> mark
  - PostToolUse of the Skill tool invoking the unattended skill   -> mark
  - any other UserPromptSubmit the user typed                    -> unmark, and
    say so in the agent's context
  - a prompt the harness injects (task notification, system
    reminder, a message from another session)                    -> no change
  - PermissionRequest while marked                               -> approve a call
    on the unattended allowance ([SK-24]), deny anything else; log either way
  - PreToolUse of AskUserQuestion while marked                   -> deny, and log it

The marker is the file the engine checks to escalate an `ask` to `deny`
([OUT-09]); `unattended_marker` in watchdog.py names it for both.

Run from a shell, `on`, `off` and `status` set or read the marker for the session
named by $CLAUDE_CODE_SESSION_ID.

Stdlib-only, no network.
"""

import json
import os
import re
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from watchdog import record_unattended, unattended_allowance, unattended_marker  # noqa: E402

SKILL_NAMES = ("unattended", "ClaudeWatch:unattended")
_INVOCATION = re.compile(r"^\s*/(ClaudeWatch:)?unattended(\s|$)")
_INJECTED = re.compile(r"^\s*(<task-notification>|<system-reminder|Another Claude session sent a message)")
_SUBCOMMAND_TOOLS = {"git", "dotnet", "glab", "gh", "npm", "just", "docker"}
_SUBCOMMAND_LIKE = re.compile(r"^[a-z][a-z-]*$")


def _now():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _mark(marker):
    os.makedirs(os.path.dirname(marker), mode=0o700, exist_ok=True)
    with open(marker, "w") as f:
        f.write(_now() + "\n")


def _shape(tool, tool_input):
    """The call's shape for the denial message and log: never its arguments."""
    if tool != "Bash":
        return tool
    lines = str(tool_input.get("command") or "").splitlines()
    words = lines[0].split() if lines else []
    if not words:
        return "Bash"
    shape = f"Bash {words[0]}"
    i = 1
    # Step over `git -C <path>` and `-c <key=value>` to reach the subcommand.
    while words[0] == "git" and i < len(words) and words[i] in ("-C", "-c"):
        i += 2
    if words[0] in _SUBCOMMAND_TOOLS and i < len(words) and _SUBCOMMAND_LIKE.match(words[i]):
        shape += f" {words[i]}"
    return shape


def handle(event):
    marker = unattended_marker(event.get("session_id"))
    if marker is None:
        return
    name = event.get("hook_event_name")

    if name == "UserPromptSubmit":
        prompt = str(event.get("prompt") or "")
        head = "\n".join(prompt.splitlines()[:3])
        if any(_INJECTED.match(line) for line in head.splitlines()):
            return
        first = prompt.splitlines()[0] if prompt else ""
        if _INVOCATION.match(first):
            _mark(marker)
        elif os.path.isfile(marker):
            os.remove(marker)
            print("unattended: off. The user sent a prompt, so permission prompts and "
                  "ClaudeWatch's ask tier reach them again. If they say they're stepping "
                  f"away again, run `python3 \"{os.path.abspath(__file__)}\" on`.")

    elif name == "PostToolUse":
        skill = (event.get("tool_input") or {}).get("skill")
        if skill in SKILL_NAMES:
            _mark(marker)

    elif name == "PreToolUse":
        if event.get("tool_name") != "AskUserQuestion" or not os.path.isfile(marker):
            return
        record_unattended(event.get("session_id"), "DENY", "AskUserQuestion")
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "Unattended session: nobody is here to answer. Make the most "
                                        "defensible call, record it in NOTES.md, and keep going.",
        }}))

    elif name == "PermissionRequest":
        if not os.path.isfile(marker):
            return
        tool = event.get("tool_name") or "unknown"
        tool_input = event.get("tool_input") or {}
        allowance = unattended_allowance(str(tool_input.get("command") or "")) if tool == "Bash" else None
        if allowance:
            record_unattended(event.get("session_id"), "ALLOW", f"{allowance} (host permission prompt approved)")
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            }}))
            return
        shape = _shape(tool, tool_input)
        record_unattended(event.get("session_id"), "DENY", shape)
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "deny",
                "message": f"Unattended session: nobody is here to approve {shape}. "
                           "Take another route, or leave this step prepared in the review map.",
            },
        }}))


def cli(command):
    marker = unattended_marker(os.environ.get("CLAUDE_CODE_SESSION_ID"))
    if marker is None:
        print("CLAUDE_CODE_SESSION_ID is unset or malformed", file=sys.stderr)
        return 2
    sid = os.path.basename(marker)
    if command == "on":
        _mark(marker)
        print(f"unattended: on ({sid})")
    elif command == "off":
        if os.path.isfile(marker):
            os.remove(marker)
        print(f"unattended: off ({sid})")
    elif command == "status":
        if os.path.isfile(marker):
            with open(marker) as f:
                print(f"unattended: on since {f.read().strip()} ({sid})")
        else:
            print(f"unattended: off ({sid})")
        if os.path.isfile(marker + ".log"):
            with open(marker + ".log") as f:
                verdicts = [line.split("\t")[1] for line in f if line.count("\t") >= 2]
            print(f"denied: {verdicts.count('DENY')}, allowed: {verdicts.count('ALLOW')} (log: {marker}.log)")
    else:
        print("usage: unattended.py [on|off|status]", file=sys.stderr)
        return 2
    return 0


def main():
    if len(sys.argv) > 1:
        sys.exit(cli(sys.argv[1]))
    # Any failure exits non-zero, so the hooks declaring `onFailure: block`
    # deny rather than leave a prompt waiting ([HK-06]).
    event = json.loads(sys.stdin.read())
    if not isinstance(event, dict):
        sys.exit(f"unattended: hook input is not a JSON object: {type(event).__name__}")
    handle(event)


if __name__ == "__main__":
    main()
