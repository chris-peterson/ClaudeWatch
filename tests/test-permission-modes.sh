#!/bin/bash
# Tests that the engine's decision is a function of the command, not of the
# session's permission mode ([OUT-04], [OUT-08]).
#
# The host does not honor an `ask` in every mode — see [OUT-04]'s note and
# https://github.com/anthropics/claude-code/issues/89561. That is the host's
# half of the contract and nothing the engine can assert from here. What this
# file pins is the engine's half: the same command grades the same way whatever
# mode it arrives under, so a future attempt to vary the decision by mode
# changes a test rather than slipping through.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/harness.sh"

RULES="$RULES_DIR"

# Every mode `--permission-mode` accepts on Claude Code 2.1.273, plus the
# absent-field case a non-Claude-Code caller produces.
MODES=(auto default acceptEdits plan bypassPermissions manual dontAsk)

bash_input() {
  local mode="$1" command="$2"
  python3 -c '
import json, sys
mode, command = sys.argv[1], sys.argv[2]
payload = {"tool_name": "Bash", "tool_input": {"command": command}}
if mode != "__absent__":
    payload["permission_mode"] = mode
print(json.dumps(payload))
' "$mode" "$command"
}

echo "Running permission-mode tests..."

echo "--- a guarded bare command grades ask in every mode ---"
for mode in "${MODES[@]}" __absent__; do
  run_test "$RULES" "git stash list -> ask (mode: $mode)" ask \
    "$(bash_input "$mode" 'git stash list')"
done

echo "--- the compound escalation fires in every mode ---"
for mode in "${MODES[@]}" __absent__; do
  run_test "$RULES" "git push | tail -> deny (mode: $mode)" block \
    "$(bash_input "$mode" 'git push 2>&1 | tail -3')"
done

echo "--- a block rule denies in every mode ---"
for mode in "${MODES[@]}" __absent__; do
  run_test "$RULES" "git push --force -> deny (mode: $mode)" block \
    "$(bash_input "$mode" 'git push --force')"
done

echo "--- an unguarded command stays silent in every mode ---"
for mode in "${MODES[@]}" __absent__; do
  run_test "$RULES" "git status -> allow (mode: $mode)" allow \
    "$(bash_input "$mode" 'git status --short')"
done

print_results
