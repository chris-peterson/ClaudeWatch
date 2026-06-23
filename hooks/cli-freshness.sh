#!/usr/bin/env bash
# SessionStart hook: no-op for ClaudeWatch.
#
# ClaudeWatch is a pure-hook plugin (PreToolUse → Bash via watchdog.py).
# It does not install a CLI wrapper on PATH, so the install-cli wrapper
# drift problem that beacon/tack/logbook handle here does not apply.
#
# This empty handler exists for symmetry across the chris-peterson plugin
# namespace and as a placeholder for future plugin-update self-checks
# specific to a hook plugin (e.g., verifying watchdog.py emits the
# expected hookSpecificOutput.permissionDecision schema — the kind of
# regression that shipped silently in 0.2.0 and would have been caught
# by a session-start probe).

exit 0
