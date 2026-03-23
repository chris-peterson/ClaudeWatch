#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../rules/watch-git.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-git ==="

echo "--- block: force push ---"
t "--force"             block '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
t "--force-with-lease"  block '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin feature"}}'
t "-f"                  block '{"tool_name":"Bash","tool_input":{"command":"git push -f origin feature"}}'

echo "--- block: reset --hard ---"
t "--hard"              block '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"}}'
t "--hard HEAD~3"       block '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~3"}}'

echo "--- block: checkout . ---"
t "checkout ."          block '{"tool_name":"Bash","tool_input":{"command":"git checkout ."}}'

echo "--- block: checkout -- ---"
t "checkout -- file"    block '{"tool_name":"Bash","tool_input":{"command":"git checkout -- src/main.rs"}}'

echo "--- block: restore . ---"
t "restore ."           block '{"tool_name":"Bash","tool_input":{"command":"git restore ."}}'

echo "--- block: clean -f ---"
t "-f"                  block '{"tool_name":"Bash","tool_input":{"command":"git clean -f"}}'
t "-xdf"                block '{"tool_name":"Bash","tool_input":{"command":"git clean -xdf"}}'
t "-n (dry run)"        allow '{"tool_name":"Bash","tool_input":{"command":"git clean -n"}}'

echo "--- block: branch -D ---"
t "-D"                  block '{"tool_name":"Bash","tool_input":{"command":"git branch -D unmerged-feature"}}'
t "-d (lowercase)"      allow '{"tool_name":"Bash","tool_input":{"command":"git branch -d merged-feature"}}'

echo "--- block: stash drop/clear ---"
t "drop"                block '{"tool_name":"Bash","tool_input":{"command":"git stash drop stash@{0}"}}'
t "clear"               block '{"tool_name":"Bash","tool_input":{"command":"git stash clear"}}'

echo "--- block: reflog expire/delete ---"
t "expire"              block '{"tool_name":"Bash","tool_input":{"command":"git reflog expire --expire=now --all"}}'
t "delete"              block '{"tool_name":"Bash","tool_input":{"command":"git reflog delete HEAD@{2}"}}'

echo "--- ask: add ---"
t "add file"            ask   '{"tool_name":"Bash","tool_input":{"command":"git add src/main.rs"}}'
t "add ."               ask   '{"tool_name":"Bash","tool_input":{"command":"git add ."}}'

echo "--- ask: rm ---"
t "rm file"             ask   '{"tool_name":"Bash","tool_input":{"command":"git rm README.md"}}'
t "rm -r dir"           ask   '{"tool_name":"Bash","tool_input":{"command":"git rm -r src/old-module"}}'
t "rm --cached"         ask   '{"tool_name":"Bash","tool_input":{"command":"git rm --cached src/secret.txt"}}'
t "rm --cached -r"      ask   '{"tool_name":"Bash","tool_input":{"command":"git rm --cached -r .claude/skills"}}'

echo "--- ask: reset ---"
t "reset --soft"        ask   '{"tool_name":"Bash","tool_input":{"command":"git reset --soft HEAD~1"}}'
t "reset (mixed)"       ask   '{"tool_name":"Bash","tool_input":{"command":"git reset HEAD~1"}}'

echo "--- ask: commit ---"
t "commit -m"           ask   '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: update readme\""}}'
t "heredoc commit"      ask   '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(cat <<'"'"'EOF'"'"'\nfix\nEOF\n)\""}}'
t "add && commit"       ask   '{"tool_name":"Bash","tool_input":{"command":"git add . && git commit -m \"test\""}}'

echo "--- ask: stash ---"
t "stash"               ask   '{"tool_name":"Bash","tool_input":{"command":"git stash"}}'
t "stash pop"           ask   '{"tool_name":"Bash","tool_input":{"command":"git stash pop"}}'

echo "--- ask: push ---"
t "push"                ask   '{"tool_name":"Bash","tool_input":{"command":"git push"}}'
t "push origin"         ask   '{"tool_name":"Bash","tool_input":{"command":"git push origin feature-branch"}}'
t "push -u"             ask   '{"tool_name":"Bash","tool_input":{"command":"git push -u origin main"}}'

echo "--- allow: safe operations ---"
t "status"              allow '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
t "log"                 allow '{"tool_name":"Bash","tool_input":{"command":"git log --oneline -10"}}'
t "diff"                allow '{"tool_name":"Bash","tool_input":{"command":"git diff HEAD~1"}}'
t "show"                allow '{"tool_name":"Bash","tool_input":{"command":"git show HEAD"}}'
t "fetch"               allow '{"tool_name":"Bash","tool_input":{"command":"git fetch --all"}}'
t "pull"                allow '{"tool_name":"Bash","tool_input":{"command":"git pull origin main"}}'
t "checkout branch"     allow '{"tool_name":"Bash","tool_input":{"command":"git checkout feature-branch"}}'
t "checkout -b"         allow '{"tool_name":"Bash","tool_input":{"command":"git checkout -b new-feature"}}'
t "mv"                  allow '{"tool_name":"Bash","tool_input":{"command":"git mv old.md new.md"}}'
t "log | head"          allow '{"tool_name":"Bash","tool_input":{"command":"git log --oneline | head -5"}}'

echo "--- allow: not git ---"
t "non-git command"     allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
t "empty command"       allow '{"tool_name":"Bash","tool_input":{"command":""}}'
t "git in string"       allow '{"tool_name":"Bash","tool_input":{"command":"echo git is great"}}'
t "Write tool"          allow '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'
t "Read tool"           allow '{"tool_name":"Read","tool_input":{"file_path":"test.txt"}}'
t "Edit tool"           allow '{"tool_name":"Edit","tool_input":{"file_path":"test.txt"}}'

print_results
