#!/bin/bash
# Tests for the hook wiring in hooks/hooks.yml ([HK-01], [HK-05]). hooks.json is
# generated from this file in CI, so the source of record is what gets checked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_YML="${1:-$SCRIPT_DIR/../hooks/hooks.yml}"

echo "Running hook wiring tests..."
python3 - "$HOOKS_YML" <<'PY'
import re
import sys

GREEN, RED, NC = "\033[0;32m", "\033[0;31m", "\033[0m"
GUARD_MATCHERS = ("Bash|Monitor", "Write|Edit")

text = open(sys.argv[1], encoding="utf-8").read()
entries = [dict(re.findall(r"(?m)^\s*(\w+):\s*(.*?)\s*$", block)) for block in re.split(r"(?m)^  - ", text)[1:]]
guards = {e.get("matcher"): e for e in entries if e.get("event") == "PreToolUse"}

passed = failed = 0
for matcher in GUARD_MATCHERS:
    entry = guards.get(matcher)
    on_failure = entry.get("onFailure") if entry else None
    if on_failure == "block":
        passed += 1
        print(f"  {GREEN}PASS{NC}: {matcher} guard declares onFailure: block")
    else:
        failed += 1
        found = "no such PreToolUse entry" if entry is None else f"onFailure: {on_failure or 'absent'}"
        print(f"  {RED}FAIL{NC}: {matcher} guard declares onFailure: block ({found})")

print()
print(f"Results: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
