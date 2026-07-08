#!/usr/bin/env python3
"""
mute: manage per-session ClaudeWatch mutes ([MUTE-01..MUTE-08], [HK-05]).

A *session mute* silences a rule set's or an individual ask rule's prompts for
the duration of one Claude Code session. Mutes suppress *ask* rules only — block
rules are never mutable ([MUTE-01]). This is the write/read side of the feature;
the engine (`watchdog.py`) does the read on the decision path.

Subcommands:
  add <name>...      mute a rule set (`git` / `watch-git`) or ask rule (`git commit`)
  remove <name>...   clear a mute
  list               show this session's active mutes
  session-end        (SessionEnd hook, [HK-05]) delete this session's mute file

`add` / `remove` / `list` take the active session id via `--session`, which the
mute skill supplies from Claude Code's `${CLAUDE_SESSION_ID}` skill substitution
([MUTE-05]) — the same id the engine keys its read on, so a mute always lands on
the session that requested it. Individual rules are named by the same label the
ask prompt shows (e.g. `git commit`), not a positional id, so the token is
discoverable and doesn't drift when rules move. Read-only of the rules,
stdlib-only, no network. The store path comes from `watchdog` so the engine and
this tool agree.
"""

import argparse
import glob
import json
import os
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from watchdog import (  # noqa: E402
    parse_rules_yml,
    load_session_mutes,
    mutes_dir,
    mute_file,
    short_set_name,
    valid_session_id,
)

DEFAULT_WATCHES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "watches")


def load_catalog(watches_dir):
    """Index the enabled rule sets into the lookups `resolve` needs.

    Returns a dict with:
      set_asks:    short -> [ask rule name, ...]  (file order)
      set_full:    short -> full set name (`watch-git`)
      set_block:   short -> bool (has any block rule)
      ask_names:   set of every ask rule name
      block_names: set of every block rule name
    """
    cat = {"set_asks": {}, "set_full": {}, "set_block": {},
           "ask_names": set(), "block_names": set()}
    for path in sorted(glob.glob(os.path.join(watches_dir, "*.yml"))):
        try:
            config = parse_rules_yml(path)
        except Exception as e:
            # The engine degrades a malformed rule set to a deny and moves on
            # (watchdog.main); the CLI has no decision to make, so surface the
            # bad file on stderr and skip it rather than crash the whole mute
            # command over one unreadable set.
            print(f"mute: skipping unreadable rule set {os.path.basename(path)}: {e}", file=sys.stderr)
            continue
        name = config.get("name") or ""
        if not name:
            continue
        short = short_set_name(name)
        cat["set_full"][short] = name
        rules = config.get("rules", {})
        asks = [r.get("name") for r in rules.get("ask", []) if r.get("name")]
        cat["set_asks"][short] = asks
        cat["ask_names"].update(asks)
        blocks = rules.get("block", [])
        cat["set_block"][short] = bool(blocks)
        cat["block_names"].update(r.get("name") for r in blocks if r.get("name"))
    return cat


def resolve(token, cat):
    """Map a user token to a mute decision.

    Returns (canonical, silenced, note):
      canonical — the token to store (set short name or rule name), or None to skip
      silenced  — list of ask rule names this mute silences
      note      — a message to show the user (why it was a no-op), or None
    """
    short = token[len("watch-"):] if token.startswith("watch-") else token
    if short in cat["set_full"]:
        asks = cat["set_asks"].get(short, [])
        if not asks:
            extra = " (its rules are all block rules, which are un-bypassable)" if cat["set_block"].get(short) else ""
            return None, [], f"'{token}' has no ask rules; nothing to mute{extra}"
        return short, asks, None
    if token in cat["ask_names"]:
        return token, [token], None
    if token in cat["block_names"]:
        return None, [], f"'{token}' is a block rule; block rules are un-bypassable and can't be muted"
    return None, [], f"no rule or rule set named '{token}'"


def _session_or_error(args):
    """The active session id from `--session`, or None after explaining the miss.

    The mute skill passes `${CLAUDE_SESSION_ID}` here ([MUTE-05]); it is the same
    id the engine keys its read on, so no cwd/pointer indirection is involved.
    """
    if not args.session:
        print("Could not resolve the active ClaudeWatch session.\n"
              "The mute skill supplies it via --session \"${CLAUDE_SESSION_ID}\"; run "
              "/ClaudeWatch:mute, /ClaudeWatch:unmute, or /ClaudeWatch:mutes rather than "
              "invoking mute.py directly.")
        return None
    if not valid_session_id(args.session):
        print(f"Ignoring an unsafe ClaudeWatch session id: {args.session!r}.\n"
              "Expected the id Claude Code supplies via --session \"${CLAUDE_SESSION_ID}\".")
        return None
    return args.session


def _write_mutes(session_id, names):
    os.makedirs(mutes_dir(), mode=0o700, exist_ok=True)
    dest = mute_file(session_id)
    with open(dest, "w") as f:
        json.dump({"session": session_id, "mutes": sorted(names)}, f)
    os.chmod(dest, 0o600)


def _describe_asks(names, indent="  "):
    return "\n".join(f"{indent}{name}" for name in names)


def cmd_add(args):
    session_id = _session_or_error(args)
    if not session_id:
        return 0
    cat = load_catalog(args.watches)
    current = load_session_mutes(session_id)
    added, silenced, notes = [], [], []
    for token in args.names:
        canonical, asks, note = resolve(token, cat)
        if note:
            notes.append(note)
            continue
        if canonical in current:
            notes.append(f"'{token}' was already muted")
            continue
        current.add(canonical)
        added.append(canonical)
        silenced.extend(asks)
    if added:
        _write_mutes(session_id, current)
    for note in notes:
        print(note)
    if added:
        # Dedup silenced ask names while preserving order.
        seen, unique = set(), []
        for name in silenced:
            if name not in seen:
                seen.add(name)
                unique.append(name)
        print(f"Muted {', '.join(added)} for this session. These ask prompts are now silenced:")
        print(_describe_asks(unique))
        print("Block rules still apply.")
        print(f"Clear with: /ClaudeWatch:unmute {' '.join(shlex.quote(a) for a in added)}")
    elif not notes:
        print("Nothing to mute.")
    return 0


def cmd_remove(args):
    session_id = _session_or_error(args)
    if not session_id:
        return 0
    cat = load_catalog(args.watches)
    current = load_session_mutes(session_id)
    removed, notes = [], []
    for token in args.names:
        canonical, _asks, note = resolve(token, cat)
        # Even if the token no longer resolves (e.g. a renamed rule), allow
        # removing the raw token so a stale mute can always be cleared.
        target = canonical if canonical in current else token
        if target in current:
            current.discard(target)
            removed.append(target)
        else:
            notes.append(note or f"'{token}' was not muted")
    if removed:
        _write_mutes(session_id, current)
    for note in notes:
        print(note)
    if removed:
        print(f"Unmuted {', '.join(removed)} for this session.")
        # `current` already holds the post-removal set that was just written; no
        # need to re-read the store.
        print("No active mutes remain." if not current else f"Still muted: {', '.join(sorted(current))}")
    return 0


def cmd_list(args):
    session_id = _session_or_error(args)
    if not session_id:
        return 0
    current = load_session_mutes(session_id)
    if not current:
        print("No active mutes for this session.")
        return 0
    cat = load_catalog(args.watches)
    print("Active mutes for this session:")
    for token in sorted(current):
        _canonical, asks, _note = resolve(token, cat)
        print(f"- {token}")
        if asks and asks != [token]:
            print(_describe_asks(asks, indent="    "))
    return 0


def _read_hook_input():
    try:
        return json.loads(sys.stdin.read() or "{}")
    except (ValueError, OSError):
        return {}


def cmd_session_end(_args):
    """[HK-05] Delete this session's mute file so a mute never outlives its session."""
    data = _read_hook_input()
    session_id = data.get("session_id")
    if not session_id:
        return 0
    try:
        os.remove(mute_file(session_id))
    except (OSError, ValueError):
        pass
    return 0


def main():
    parser = argparse.ArgumentParser(description="Manage per-session ClaudeWatch mutes.")
    parser.add_argument("--watches", default=DEFAULT_WATCHES, help="rule-sets directory")
    parser.add_argument("--session", default=None,
                        help="active session id (the mute skill passes ${CLAUDE_SESSION_ID})")
    sub = parser.add_subparsers(dest="command", required=True)
    p_add = sub.add_parser("add"); p_add.add_argument("names", nargs="+")
    p_rm = sub.add_parser("remove"); p_rm.add_argument("names", nargs="+")
    sub.add_parser("list")
    sub.add_parser("session-end")

    args = parser.parse_args()

    handlers = {
        "add": cmd_add, "remove": cmd_remove, "list": cmd_list,
        "session-end": cmd_session_end,
    }
    sys.exit(handlers[args.command](args))


if __name__ == "__main__":
    main()
