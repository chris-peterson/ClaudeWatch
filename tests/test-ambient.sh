#!/bin/bash
# Tests for the SessionStart ambient-guidance hook (hooks/emit-rules.mjs, [HK-04]).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EMIT="$PLUGIN_ROOT/hooks/emit-rules.mjs"

PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "Running ambient-guidance tests..."
out=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" node "$EMIT")

check() {
  local label="$1" needle="$2"
  if printf '%s' "$out" | grep -qF "$needle"; then
    PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $label"
  else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $label (missing: $needle)"
  fi
}

check "emits the plugin header" "# Ambient rules from the ClaudeWatch plugin"
check "emits the compound-command guidance heading" "Before you pipe or chain, check the lead command"
check "frames the trigger reflex" "Reaching for \`| tail\`"
check "names the escalation behavior" "from an \`ask\` prompt to a hard block"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
