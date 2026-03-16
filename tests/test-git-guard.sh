#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../scripts/git-guard.py"
RULES="$SCRIPT_DIR/../rules.yml"
PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

run_test() {
  local label="$1" expected="$2" input="$3"
  TOTAL=$((TOTAL + 1))
  result=$(echo "$input" | python3 "$HOOK" "$RULES" 2>/dev/null || true)
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

echo "=== git-guardian tests ==="

# deny: push\s.*(--force|-[a-zA-Z]*f\b)
echo "--- deny: force push ---"
run_test "--force"             block '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
run_test "--force-with-lease"  block '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin feature"}}'
run_test "-f"                  block '{"tool_name":"Bash","tool_input":{"command":"git push -f origin feature"}}'

# deny: reset\s.*--hard
echo "--- deny: reset --hard ---"
run_test "--hard"              block '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"}}'
run_test "--hard HEAD~3"       block '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~3"}}'

# deny: checkout\s+\.\s*$
echo "--- deny: checkout . ---"
run_test "checkout ."          block '{"tool_name":"Bash","tool_input":{"command":"git checkout ."}}'

# deny: checkout\s+--\s
echo "--- deny: checkout -- ---"
run_test "checkout -- file"    block '{"tool_name":"Bash","tool_input":{"command":"git checkout -- src/main.rs"}}'

# deny: restore\s+\.\s*$
echo "--- deny: restore . ---"
run_test "restore ."           block '{"tool_name":"Bash","tool_input":{"command":"git restore ."}}'

# deny: clean\s.*-[a-zA-Z]*f
echo "--- deny: clean -f ---"
run_test "-f"                  block '{"tool_name":"Bash","tool_input":{"command":"git clean -f"}}'
run_test "-xdf"                block '{"tool_name":"Bash","tool_input":{"command":"git clean -xdf"}}'
run_test "-n (dry run)"        allow '{"tool_name":"Bash","tool_input":{"command":"git clean -n"}}'

# deny: branch\s.*-[a-zA-Z]*D
echo "--- deny: branch -D ---"
run_test "-D"                  block '{"tool_name":"Bash","tool_input":{"command":"git branch -D unmerged-feature"}}'
run_test "-d (lowercase)"      allow '{"tool_name":"Bash","tool_input":{"command":"git branch -d merged-feature"}}'

# deny: stash\s+(drop|clear)
echo "--- deny: stash drop/clear ---"
run_test "drop"                block '{"tool_name":"Bash","tool_input":{"command":"git stash drop stash@{0}"}}'
run_test "clear"               block '{"tool_name":"Bash","tool_input":{"command":"git stash clear"}}'

# deny: reflog\s+(expire|delete)
echo "--- deny: reflog expire/delete ---"
run_test "expire"              block '{"tool_name":"Bash","tool_input":{"command":"git reflog expire --expire=now --all"}}'
run_test "delete"              block '{"tool_name":"Bash","tool_input":{"command":"git reflog delete HEAD@{2}"}}'

# ask: add(\s|$)
echo "--- ask: add ---"
run_test "add file"            ask   '{"tool_name":"Bash","tool_input":{"command":"git add src/main.rs"}}'
run_test "add ."               ask   '{"tool_name":"Bash","tool_input":{"command":"git add ."}}'

# ask: rm\b(?!.*--cached) | rm\s.*--cached
echo "--- ask: rm ---"
run_test "rm file"             ask   '{"tool_name":"Bash","tool_input":{"command":"git rm README.md"}}'
run_test "rm -r dir"           ask   '{"tool_name":"Bash","tool_input":{"command":"git rm -r src/old-module"}}'
run_test "rm --cached"         ask   '{"tool_name":"Bash","tool_input":{"command":"git rm --cached src/secret.txt"}}'
run_test "rm --cached -r"      ask   '{"tool_name":"Bash","tool_input":{"command":"git rm --cached -r .claude/skills"}}'

# ask: reset(\s|$)
echo "--- ask: reset ---"
run_test "reset --soft"        ask   '{"tool_name":"Bash","tool_input":{"command":"git reset --soft HEAD~1"}}'
run_test "reset (mixed)"       ask   '{"tool_name":"Bash","tool_input":{"command":"git reset HEAD~1"}}'

# ask: commit(\s|$)
echo "--- ask: commit ---"
run_test "commit -m"           ask   '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: update readme\""}}'
run_test "heredoc commit"      ask   '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(cat <<'"'"'EOF'"'"'\nfix\nEOF\n)\""}}'
run_test "add && commit"       ask   '{"tool_name":"Bash","tool_input":{"command":"git add . && git commit -m \"test\""}}'

# ask: stash(\s|$)
echo "--- ask: stash ---"
run_test "stash"               ask   '{"tool_name":"Bash","tool_input":{"command":"git stash"}}'
run_test "stash pop"           ask   '{"tool_name":"Bash","tool_input":{"command":"git stash pop"}}'

# ask: push(\s|$)
echo "--- ask: push ---"
run_test "push"                ask   '{"tool_name":"Bash","tool_input":{"command":"git push"}}'
run_test "push origin"         ask   '{"tool_name":"Bash","tool_input":{"command":"git push origin feature-branch"}}'
run_test "push -u"             ask   '{"tool_name":"Bash","tool_input":{"command":"git push -u origin main"}}'

# allow: read-only / safe operations
echo "--- allow: safe operations ---"
run_test "status"              allow '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
run_test "log"                 allow '{"tool_name":"Bash","tool_input":{"command":"git log --oneline -10"}}'
run_test "diff"                allow '{"tool_name":"Bash","tool_input":{"command":"git diff HEAD~1"}}'
run_test "show"                allow '{"tool_name":"Bash","tool_input":{"command":"git show HEAD"}}'
run_test "fetch"               allow '{"tool_name":"Bash","tool_input":{"command":"git fetch --all"}}'
run_test "pull"                allow '{"tool_name":"Bash","tool_input":{"command":"git pull origin main"}}'
run_test "checkout branch"     allow '{"tool_name":"Bash","tool_input":{"command":"git checkout feature-branch"}}'
run_test "checkout -b"         allow '{"tool_name":"Bash","tool_input":{"command":"git checkout -b new-feature"}}'
run_test "mv"                  allow '{"tool_name":"Bash","tool_input":{"command":"git mv old.md new.md"}}'
run_test "log | head"          allow '{"tool_name":"Bash","tool_input":{"command":"git log --oneline | head -5"}}'

# allow: not a git command
echo "--- allow: not git ---"
run_test "non-git command"     allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
run_test "empty command"       allow '{"tool_name":"Bash","tool_input":{"command":""}}'
run_test "git in string"       allow '{"tool_name":"Bash","tool_input":{"command":"echo git is great"}}'
run_test "Write tool"          allow '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'
run_test "Read tool"           allow '{"tool_name":"Read","tool_input":{"file_path":"test.txt"}}'
run_test "Edit tool"           allow '{"tool_name":"Edit","tool_input":{"file_path":"test.txt"}}'

echo "========================================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} out of $TOTAL"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
