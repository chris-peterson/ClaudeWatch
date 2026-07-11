#!/usr/bin/env bash
# DOCUMENTATION: Emit ClaudeWatch's ambient guidance into context.
# SessionStart hook: emit ClaudeWatch's ambient guidance into context. Stdout is
# added to context on every SessionStart (startup, resume, compaction — no
# matcher in hooks.json), so the guidance survives a compaction. It steers the
# agent away from the compound-command escalation ([OUT-08]) before it triggers:
# chaining a guarded command into a pipe turns an `ask` into a hard block, so a
# session that learns to run guarded steps standalone hits fewer dead-end blocks.

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
RULES_DIR="$PLUGIN_ROOT/rules"
[ -d "$RULES_DIR" ] || exit 0

printf '# Ambient rules from the ClaudeWatch plugin\n\n'
for f in "$RULES_DIR"/*.md; do
  [ -e "$f" ] || break
  cat "$f"
  printf '\n'
done
