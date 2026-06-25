#!/usr/bin/env bash
# PreToolUse launcher: run the watchdog engine under whichever Python interpreter
# the host provides. The hook entry invokes this script rather than naming an
# interpreter directly, so interpreter resolution is a property of the launcher
# and the same hooks.json works on macOS, Linux, and Windows (Git Bash) — see
# [HK-05], [PL-02] in SPEC.md.
#
# On a standard Windows Python install the executable is `python.exe` plus the
# `py` launcher; `python3` is not reliably on PATH. On macOS/Linux `python3` is
# the convention. Probe in that order and exec the first one found.
#
# Resolution failure is a visible error, never a silent no-op: a PreToolUse hook
# that fails to launch produces no decision, which the host reads as
# allow-by-default. There is no fallback decision ([PL-03]) — if no interpreter
# resolves, fail loudly to stderr and exit non-zero.

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
ENGINE="$PLUGIN_ROOT/scripts/watchdog.py"
WATCHES="$PLUGIN_ROOT/watches"

for interp in python3 python py; do
  if command -v "$interp" >/dev/null 2>&1; then
    exec "$interp" "$ENGINE" "$WATCHES"
  fi
done

echo "ClaudeWatch: no Python interpreter found (tried python3, python, py); the safety hook cannot run." >&2
exit 1
