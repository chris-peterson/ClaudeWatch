#!/bin/bash
# Engine decision logging (CLAUDEWATCH_LOG). Logging is an opt-in side channel
# that must not change the emitted decision or the exit code.
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

echo "=== decision logging (CLAUDEWATCH_LOG) ==="

# Run the hook with CLAUDEWATCH_LOG set, then assert the last logged record's
# "decision" field matches what the rules produce for the input.
log_decision_test() {
  local label="$1" expected_decision="$2" input="$3"
  local logfile
  logfile=$(mktemp /tmp/cw-log.XXXXXX.jsonl)
  TOTAL=$((TOTAL + 1))
  echo "$input" | CLAUDEWATCH_LOG="$logfile" python3 "$HOOK" "$RULES_DIR" >/dev/null 2>&1 || true
  local got
  got=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["decision"])' "$logfile" 2>/dev/null || true)
  rm -f "$logfile"
  if [ "$got" = "$expected_decision" ]; then
    PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $label"
  else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $label (expected decision=$expected_decision, logged: ${got:-none})"
  fi
}

log_decision_test "allow decision is logged" allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
log_decision_test "ask decision is logged"   ask   '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"x\""}}'
log_decision_test "deny decision is logged"  deny  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'

echo "--- logged record carries the command verbatim ---"
LOGFILE=$(mktemp /tmp/cw-cmd.XXXXXX.jsonl)
echo '{"tool_name":"Bash","tool_input":{"command":"ls -la /etc"}}' \
  | CLAUDEWATCH_LOG="$LOGFILE" python3 "$HOOK" "$RULES_DIR" >/dev/null 2>&1 || true
TOTAL=$((TOTAL + 1))
if python3 -c 'import json,sys; sys.exit(0 if json.loads(open(sys.argv[1]).read().splitlines()[-1]).get("command")=="ls -la /etc" else 1)' "$LOGFILE" 2>/dev/null; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: command recorded in log"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: command recorded in log"
fi
rm -f "$LOGFILE"

echo "--- logged record carries the matched rule reasons for ask/deny ---"
LOGFILE=$(mktemp /tmp/cw-matched.XXXXXX.jsonl)
echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' \
  | CLAUDEWATCH_LOG="$LOGFILE" python3 "$HOOK" "$RULES_DIR" >/dev/null 2>&1 || true
TOTAL=$((TOTAL + 1))
if python3 -c 'import json,sys; rec=json.loads(open(sys.argv[1]).read().splitlines()[-1]); sys.exit(0 if rec["decision"]=="deny" and len(rec.get("matched",[]))>=1 else 1)' "$LOGFILE" 2>/dev/null; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: matched reasons recorded for deny"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: matched reasons recorded for deny"
fi
rm -f "$LOGFILE"

echo "--- logged record carries the active permission_mode ---"
LOGFILE=$(mktemp /tmp/cw-mode.XXXXXX.jsonl)
echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"permission_mode":"auto"}' \
  | CLAUDEWATCH_LOG="$LOGFILE" python3 "$HOOK" "$RULES_DIR" >/dev/null 2>&1 || true
TOTAL=$((TOTAL + 1))
if python3 -c 'import json,sys; sys.exit(0 if json.loads(open(sys.argv[1]).read().splitlines()[-1]).get("mode")=="auto" else 1)' "$LOGFILE" 2>/dev/null; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: permission_mode recorded in log"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: permission_mode recorded in log"
fi
rm -f "$LOGFILE"

echo "--- logging is on by default: unset CLAUDEWATCH_LOG writes the default path ---"
# Sandbox HOME to a tmp dir so the default path (~/.claude/claudewatch/...)
# resolves there instead of the real user log. env -u drops the harness's
# exported CLAUDEWATCH_LOG=off so the engine sees it as unset.
HOMEDIR=$(mktemp -d /tmp/cw-home.XXXXXX)
DEFAULT_LOG="$HOMEDIR/.claude/claudewatch/decisions.jsonl"
TOTAL=$((TOTAL + 1))
echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
  | env -u CLAUDEWATCH_LOG HOME="$HOMEDIR" python3 "$HOOK" "$RULES_DIR" >/dev/null 2>&1 || true
if [ -s "$DEFAULT_LOG" ]; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: default-path log written when env unset"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: default-path log written when env unset"
fi
rm -rf "$HOMEDIR"

echo "--- opt-out: CLAUDEWATCH_LOG=off writes no log ---"
for off_value in off 0 false none ""; do
  HOMEDIR=$(mktemp -d /tmp/cw-off.XXXXXX)
  DEFAULT_LOG="$HOMEDIR/.claude/claudewatch/decisions.jsonl"
  TOTAL=$((TOTAL + 1))
  echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
    | CLAUDEWATCH_LOG="$off_value" HOME="$HOMEDIR" python3 "$HOOK" "$RULES_DIR" >/dev/null 2>&1 || true
  if [ ! -e "$DEFAULT_LOG" ]; then
    PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: no log written for CLAUDEWATCH_LOG='${off_value}'"
  else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: no log written for CLAUDEWATCH_LOG='${off_value}'"
  fi
  rm -rf "$HOMEDIR"
done

print_results
