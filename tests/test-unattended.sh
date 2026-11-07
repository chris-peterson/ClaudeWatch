#!/bin/bash
# Unattended sessions: the engine escalation ([OUT-09]) and the hook that keeps
# the marker ([SK-20]-[SK-23], scripts/unattended.py). HOME is sandboxed so the
# marker lands in a scratch directory, never the real ~/.claude.
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

UNATTENDED="$SCRIPT_DIR/../scripts/unattended.py"
SANDBOX=$(mktemp -d /tmp/cw-unattended.XXXXXX)
export HOME="$SANDBOX"
MARKERS="$SANDBOX/.claude/claudewatch/unattended"
SID="sess-1"

check() {
  local label="$1" ok="$2"
  TOTAL=$((TOTAL + 1))
  if [ "$ok" = yes ]; then
    PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $label"
  else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $label"
  fi
}

has() { if printf '%s' "$1" | grep -qF -- "$2"; then echo yes; else echo no; fi; }
exists() { if [ -f "$1" ]; then echo yes; else echo no; fi; }
absent() { if [ -f "$1" ]; then echo no; else echo yes; fi; }

hook() { printf '%s' "$1" | python3 "$UNATTENDED" 2>/dev/null; }

bash_input() { printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"%s"}}' "${2:-$SID}" "$1"; }

PUSH=$(bash_input "git push origin main")
FORCE=$(bash_input "git push --force")
STATUS=$(bash_input "git status")

echo "=== engine: an unattended session cannot be asked ==="
run_test "$RULES_DIR" "attended: push asks" ask "$PUSH"
mkdir -p "$MARKERS"
touch "$MARKERS/$SID"
run_test "$RULES_DIR" "unattended: push is denied" block "$PUSH"
out=$(printf '%s' "$PUSH" | python3 "$HOOK" "$RULES_DIR")
check "the denial says nobody is here to answer" "$(has "$out" "unattended session: escalated to block")"
check "the denial keeps the rule's own reason" "$(has "$out" "git push")"
run_test "$RULES_DIR" "unattended: a block stays a block" block "$FORCE"
run_test "$RULES_DIR" "unattended: an unguarded command stays silent" allow "$STATUS"
run_test "$RULES_DIR" "another session's marker does not apply" ask "$(bash_input "git push origin main" sess-2)"
run_test "$RULES_DIR" "a session id with a path in it names no marker" ask \
  "$(bash_input "git push origin main" "../unattended/$SID")"

echo "--- engine: the unattended allowance ([SK-24]) ---"
DECISIONS="$SANDBOX/decisions.jsonl"
out=$(bash_input "git commit -F msg.txt" | CLAUDEWATCH_LOG="$DECISIONS" python3 "$HOOK" "$RULES_DIR")
check "unattended: a bare commit stays silent" "$( [ -z "$out" ] && echo yes || echo no)"
check "the allowance is an ALLOW line in the session log" "$(has "$(cat "$MARKERS/$SID.log")" "ALLOW	git commit (ClaudeWatch ask not escalated: git commit)")"
check "and an unattended_allow field on the decision record" "$(has "$(tail -n 1 "$DECISIONS")" '"unattended_allow":"git commit"')"
run_test "$RULES_DIR" "unattended: commit under git -C is allowed" allow "$(bash_input "git -C /repo commit -m wip")"
run_test "$RULES_DIR" "unattended: commit --amend is denied" block "$(bash_input "git commit --amend --no-edit")"
run_test "$RULES_DIR" "unattended: a chained commit is denied" block "$(bash_input "git add . && git commit -m wip")"
run_test "$RULES_DIR" "attended: a bare commit still asks" ask "$(bash_input "git commit -m wip" sess-2)"
rm -f "$MARKERS/$SID" "$MARKERS/$SID.log"

echo "--- hook: marking and unmarking ---"
hook '{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID"'","prompt":"/ClaudeWatch:unattended finish the migration"}' >/dev/null
check "typing /ClaudeWatch:unattended marks the session" "$(exists "$MARKERS/$SID")"
rm -f "$MARKERS/$SID"
hook '{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID"'","prompt":"/unattended"}' >/dev/null
check "typing /unattended marks the session" "$(exists "$MARKERS/$SID")"
hook '{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID"'","prompt":"<task-notification>\nbuild finished"}' >/dev/null
check "an injected notification leaves the mark" "$(exists "$MARKERS/$SID")"
out=$(hook '{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID"'","prompt":"back, what happened?"}')
check "a typed prompt clears the mark" "$(absent "$MARKERS/$SID")"
check "and says so in context" "$(has "$out" "unattended: off")"
out=$(hook '{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID"'","prompt":"another question"}')
check "a typed prompt while attended says nothing" "$( [ -z "$out" ] && echo yes || echo no)"
hook '{"hook_event_name":"PostToolUse","session_id":"'"$SID"'","tool_name":"Skill","tool_input":{"skill":"ClaudeWatch:unattended"}}' >/dev/null
check "the agent invoking the skill marks the session" "$(exists "$MARKERS/$SID")"
rm -f "$MARKERS/$SID"
hook '{"hook_event_name":"PostToolUse","session_id":"'"$SID"'","tool_name":"Skill","tool_input":{"skill":"ClaudeWatch:learn"}}' >/dev/null
check "another skill leaves it unmarked" "$(absent "$MARKERS/$SID")"

echo "--- hook: permission prompts ---"
perm() { printf '{"hook_event_name":"PermissionRequest","session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$SID" "$1"; }
PERM=$(perm "git -C /repo push s3cr3t-remote")
out=$(hook "$PERM")
check "attended: a permission prompt passes through" "$( [ -z "$out" ] && echo yes || echo no)"
touch "$MARKERS/$SID"
out=$(hook "$PERM")
check "unattended: a permission prompt is denied" "$(has "$out" '"behavior": "deny"')"
check "the denial names the shape past git -C" "$(has "$out" "approve Bash git push")"
check "the log records a DENY line with the shape" "$(has "$(cat "$MARKERS/$SID.log")" "DENY	Bash git push")"
check "the log never records arguments" "$( grep -q s3cr3t "$MARKERS/$SID.log" && echo no || echo yes)"
for cmd in "git switch -c feature" "git checkout -b feature" "git add src" "git commit -F msg.txt"; do
  out=$(hook "$(perm "$cmd")")
  check "unattended: the host prompt for '$cmd' is approved" "$(has "$out" '"behavior": "allow"')"
done
check "each approval is an ALLOW line" "$(has "$(cat "$MARKERS/$SID.log")" "ALLOW	git switch (host permission prompt approved)")"
for cmd in "git switch -f main" "git switch --discard-changes main" "git checkout main" "git add . && git push"; do
  out=$(hook "$(perm "$cmd")")
  check "unattended: the host prompt for '$cmd' is denied" "$(has "$out" '"behavior": "deny"')"
done

echo "--- hook: questions to the user ([SK-25]) ---"
ASK='{"hook_event_name":"PreToolUse","session_id":"'"$SID"'","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}'
out=$(hook "$ASK")
check "unattended: AskUserQuestion is denied" "$(has "$out" '"permissionDecision": "deny"')"
check "the denial says to decide and log it" "$(has "$out" "record it in NOTES.md")"
check "the denial is a DENY line" "$(has "$(cat "$MARKERS/$SID.log")" "DENY	AskUserQuestion")"
rm -f "$MARKERS/$SID"
out=$(hook "$ASK")
check "attended: AskUserQuestion passes through" "$( [ -z "$out" ] && echo yes || echo no)"

echo "--- hook: failures exit non-zero so onFailure: block applies ---"
for bad in "not json" "[]" ""; do
  if printf '%s' "$bad" | python3 "$UNATTENDED" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  check "unreadable input '$bad' exits non-zero" "$( [ "$rc" -ne 0 ] && echo yes || echo no)"
done

echo "--- cli ---"
rm -f "$MARKERS/$SID" "$MARKERS/$SID.log"
out=$(CLAUDE_CODE_SESSION_ID="$SID" python3 "$UNATTENDED" on)
check "on marks the session" "$(exists "$MARKERS/$SID")"
hook "$PERM" >/dev/null
hook "$(perm "git commit -m wip")" >/dev/null
hook "$(perm "git add src")" >/dev/null
out=$(CLAUDE_CODE_SESSION_ID="$SID" python3 "$UNATTENDED" status)
check "status reports on" "$(has "$out" "unattended: on since")"
check "status counts denials and allowances apart" "$(has "$out" "denied: 1, allowed: 2")"
CLAUDE_CODE_SESSION_ID="$SID" python3 "$UNATTENDED" off >/dev/null
check "off clears the mark" "$(absent "$MARKERS/$SID")"
if CLAUDE_CODE_SESSION_ID="a/b" python3 "$UNATTENDED" on >/dev/null 2>&1; then rc=0; else rc=$?; fi
check "a malformed session id exits non-zero" "$( [ "$rc" -ne 0 ] && echo yes || echo no)"

rm -rf "$SANDBOX"
print_results
