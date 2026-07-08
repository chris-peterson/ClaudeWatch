#!/bin/bash
# Session mute tests ([MUTE-01..MUTE-08], [HK-05]).
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

# Isolate the mute store in a temp home so the suite never touches the real one.
export CLAUDEWATCH_HOME="$(mktemp -d)"
MUTES="$CLAUDEWATCH_HOME/mutes"
mkdir -p "$MUTES"
MUTE="$SCRIPT_DIR/../scripts/mute.py"
GIT="$RULES_DIR/watch-git.yml"
SESS="test-session-1"

# Individual ask rules are muted by their name (the label the prompt shows),
# e.g. "git commit" / "git reset --hard".

check() {  # label, haystack, needle
  local label="$1" hay="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $label"
  else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $label (missing: $needle)"
  fi
}

check_absent() {  # label, haystack, needle
  local label="$1" hay="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $label (unexpected: $needle)"
  else
    PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $label"
  fi
}

inp() {  # command -> hook input JSON carrying the test session id
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"session_id":"%s"}' "$1" "$SESS"
}

echo "=== engine honors a session mute ([MUTE-01..MUTE-03]) ==="

printf '{"mutes":["git"]}' > "$MUTES/$SESS.json"
run_test "$GIT" "muted set 'git': git commit is allowed"        allow "$(inp 'git commit -m x')"
run_test "$GIT" "muted set 'git': git reset --hard is allowed"  allow "$(inp 'git reset --hard')"
run_test "$GIT" "muted set 'git': block (push --force) still fires" block "$(inp 'git push --force')"

printf '{"mutes":["git commit"]}' > "$MUTES/$SESS.json"
run_test "$GIT" "muted rule 'git commit': git commit is allowed"        allow "$(inp 'git commit -m x')"
run_test "$GIT" "muted rule 'git commit': git reset --hard still asks"  ask   "$(inp 'git reset --hard')"

rm -f "$MUTES/$SESS.json"
run_test "$GIT" "no mute: git commit asks as normal"            ask   "$(inp 'git commit -m x')"

echo "=== friction hint on the ask prompt ([MUTE-08]) ==="
hint_out=$(inp 'git commit -m x' | python3 "$HOOK" "$GIT" 2>/dev/null || true)
check "ask reason carries the mute hint" "$hint_out" "Mute for this session: /ClaudeWatch:mute 'git commit'"
block_out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git push --force"},"session_id":"%s"}' "$SESS" | python3 "$HOOK" "$GIT" 2>/dev/null || true)
check_absent "block reason carries no mute hint" "$block_out" "Mute for this session"

echo "=== CLI: --session add, list, remove, no-ops ([MUTE-04..MUTE-07]) ==="
# The skill passes the session id via --session ${CLAUDE_SESSION_ID}; the id
# matches the one the engine reads on stdin, so the write lands where the read
# looks — no cwd/pointer indirection.
add_out=$(python3 "$MUTE" --watches "$RULES_DIR" --session "$SESS" add git)
check "add 'git' names the silenced commit rule" "$add_out" "git commit"
check "add 'git' explains how to clear"          "$add_out" "/ClaudeWatch:unmute git"
check "add 'git' notes block rules still apply"  "$add_out" "Block rules still apply"
check "mute file records the canonical token"    "$(cat "$MUTES/$SESS.json")" '"git"'
run_test "$GIT" "CLI-applied mute silences git commit" allow "$(inp 'git commit -m x')"

no_session_out=$(python3 "$MUTE" --watches "$RULES_DIR" add git 2>&1)
check "add without --session reports the miss" "$no_session_out" "Could not resolve the active ClaudeWatch session"

noop_out=$(python3 "$MUTE" --watches "$RULES_DIR" --session "$SESS" add "git push --force")
check "muting a block rule is a reported no-op" "$noop_out" "block rules are un-bypassable"
unknown_out=$(python3 "$MUTE" --watches "$RULES_DIR" --session "$SESS" add nonesuch)
check "muting an unknown name is reported" "$unknown_out" "no rule or rule set named 'nonesuch'"

list_out=$(python3 "$MUTE" --watches "$RULES_DIR" --session "$SESS" list)
check "list shows the muted set" "$list_out" "git"
rm_out=$(python3 "$MUTE" --watches "$RULES_DIR" --session "$SESS" remove git)
check "remove confirms the unmute" "$rm_out" "Unmuted git"
run_test "$GIT" "after unmute, git commit asks again" ask "$(inp 'git commit -m x')"

echo "=== CLI rejects an unsafe session id (no path escape) ==="
canary="$CLAUDEWATCH_HOME/canary.json"
rm -f "$canary"
evil_out=$(python3 "$MUTE" --watches "$RULES_DIR" --session "../canary" add git 2>&1)
check "unsafe --session is reported" "$evil_out" "unsafe ClaudeWatch session id"
check "unsafe --session writes no mute file outside the store" "$([ -f "$canary" ] && echo escaped || echo contained)" "contained"

echo "=== SessionEnd clears the session's mutes ([HK-05]) ==="
python3 "$MUTE" --watches "$RULES_DIR" --session "$SESS" add git >/dev/null
printf '{"session_id":"%s"}' "$SESS" | python3 "$MUTE" session-end
check "session-end deleted the mute file" "$([ -f "$MUTES/$SESS.json" ] && echo present || echo gone)" "gone"

print_results
