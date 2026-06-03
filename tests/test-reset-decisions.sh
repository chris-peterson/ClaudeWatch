#!/bin/bash
# Decision-log reset (scripts/reset-decisions.py). Archives by default, deletes
# with --hard, and no-ops with guidance when logging is disabled or absent.
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

# This suite captures exit codes from intentionally-failing runs, so turn off
# errexit (the harness sets `set -e`); each case asserts on $? explicitly.
set +e

RESET="$SCRIPT_DIR/../scripts/reset-decisions.py"

echo "=== decision log reset ==="

make_log() {
  cat > "$1" <<'EOF'
{"ts":"2026-05-31T10:00:00+00:00","session":"s1","decision":"allow","tool":"Bash","command":"ls"}
{"ts":"2026-05-31T10:05:00+00:00","session":"s2","decision":"ask","tool":"Bash","command":"git commit -m x","matched":["watch-git — git commit"]}
EOF
}

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $1"; }
check() { TOTAL=$((TOTAL + 1)); if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected [$2], got [$1])"; fi; }
check_grep() { TOTAL=$((TOTAL + 1)); if echo "$2" | grep -qi "$1"; then pass "$3"; else fail "$3 (output: ${2:-empty})"; fi; }

echo "--- default archives the log (recoverable) ---"
TMP=$(mktemp -d /tmp/cw-reset.XXXXXX)
LOG="$TMP/decisions.jsonl"
make_log "$LOG"
OUT=$(python3 "$RESET" --log "$LOG" 2>&1); RC=$?
check "$RC" 0 "archive exits zero"
[ -f "$LOG" ]; check "$?" 1 "original log is gone"
ls "$TMP"/archive/decisions-*.jsonl >/dev/null 2>&1; check "$?" 0 "an archive copy exists"
ARCHIVED=$(cat "$TMP"/archive/decisions-*.jsonl | wc -l | tr -d ' ')
check "$ARCHIVED" 2 "archive preserves both records"
check_grep "2 records" "$OUT" "reports record count and span"
rm -rf "$TMP"

echo "--- --hard deletes the log ---"
TMP=$(mktemp -d /tmp/cw-reset.XXXXXX)
LOG="$TMP/decisions.jsonl"
make_log "$LOG"
OUT=$(python3 "$RESET" --log "$LOG" --hard 2>&1); RC=$?
check "$RC" 0 "hard exits zero"
[ -f "$LOG" ]; check "$?" 1 "log is gone"
[ -d "$TMP/archive" ]; check "$?" 1 "no archive dir created"
check_grep "deleted" "$OUT" "reports a delete"
rm -rf "$TMP"

echo "--- logging disabled is a no-op with guidance ---"
OUT=$(CLAUDEWATCH_LOG=off python3 "$RESET" 2>&1); RC=$?
TOTAL=$((TOTAL + 1)); if [ "$RC" -ne 0 ]; then pass "disabled exits non-zero"; else fail "disabled exits non-zero (got $RC)"; fi
check_grep "disabled" "$OUT" "disabled explains why"

echo "--- missing log is a benign no-op ---"
TMP=$(mktemp -d /tmp/cw-reset.XXXXXX)
OUT=$(python3 "$RESET" --log "$TMP/nope.jsonl" 2>&1); RC=$?
check "$RC" 0 "missing log exits zero"
check_grep "nothing to reset" "$OUT" "missing log reports nothing to reset"
rm -rf "$TMP"

print_results
