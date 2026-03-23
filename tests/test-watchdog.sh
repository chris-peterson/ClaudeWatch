#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERALL_FAIL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "========================================"
echo "  claude-watchdog tests"
echo "========================================"

for test_file in "$SCRIPT_DIR"/test-watch-*.sh "$SCRIPT_DIR"/test-engine.sh; do
  echo ""
  if bash "$test_file"; then
    :
  else
    OVERALL_FAIL=1
  fi
done

echo ""
if [ "$OVERALL_FAIL" -gt 0 ]; then
  echo -e "${RED}Some test suites failed.${NC}"
  exit 1
else
  echo -e "${GREEN}All test suites passed.${NC}"
fi
