#!/bin/bash
# Shared test harness for watchdog rule tests.
# Source this file from individual test scripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../scripts/watchdog.py"
RULES_DIR="$SCRIPT_DIR/../rules"
PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

run_test() {
  local rules="$1" label="$2" expected="$3" input="$4"
  TOTAL=$((TOTAL + 1))
  result=$(echo "$input" | python3 "$HOOK" "$rules" 2>/dev/null || true)
  case "$expected" in
    ask)
      if echo "$result" | grep -q '"decision":"ask"'; then
        PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $label"
      else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $label (expected ask, got: ${result:-empty})"
      fi ;;
    block)
      if echo "$result" | grep -q '"decision":"block"'; then
        PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $label"
      else
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $label (expected block, got: ${result:-empty})"
      fi ;;
    allow)
      if echo "$result" | grep -qE '"decision"'; then
        FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $label (expected allow, got: $result)"
      else
        PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $label"
      fi ;;
    *)
      FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $label (unknown expectation: $expected)" ;;
  esac
}

print_results() {
  echo ""
  echo "========================================="
  echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} out of $TOTAL"
  echo "========================================="
  if [ "$FAIL" -gt 0 ]; then
    exit 1
  fi
}
