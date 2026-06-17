#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../rules/watch-git.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-git ==="

echo "--- block: force push ---"
t "--force"             block '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
t "-f"                  block '{"tool_name":"Bash","tool_input":{"command":"git push -f origin feature"}}'

echo "--- block: checkout . ---"
t "checkout ."          block '{"tool_name":"Bash","tool_input":{"command":"git checkout ."}}'

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

echo "--- allow: stage manipulation ---"
t "add file"            allow '{"tool_name":"Bash","tool_input":{"command":"git add src/main.rs"}}'
t "add ."               allow '{"tool_name":"Bash","tool_input":{"command":"git add ."}}'
t "rm file"             allow '{"tool_name":"Bash","tool_input":{"command":"git rm README.md"}}'
t "rm -r dir"           allow '{"tool_name":"Bash","tool_input":{"command":"git rm -r src/old-module"}}'
t "rm --cached"         allow '{"tool_name":"Bash","tool_input":{"command":"git rm --cached src/secret.txt"}}'
t "rm --cached -r"      allow '{"tool_name":"Bash","tool_input":{"command":"git rm --cached -r .claude/skills"}}'
t "reset --soft"        allow '{"tool_name":"Bash","tool_input":{"command":"git reset --soft HEAD~1"}}'
t "reset (mixed)"       allow '{"tool_name":"Bash","tool_input":{"command":"git reset HEAD~1"}}'

echo "--- ask: checkout -- <file> ---"
t "checkout -- file"    ask   '{"tool_name":"Bash","tool_input":{"command":"git checkout -- src/main.rs"}}'
t "checkout -- ."       ask   '{"tool_name":"Bash","tool_input":{"command":"git checkout -- ."}}'

echo "--- ask: reset --hard (boundary vs allowed non-hard reset) ---"
t "reset --hard"        ask   '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"}}'
t "reset --hard HEAD~3" ask   '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~3"}}'
t "reset --hard=no"     ask   '{"tool_name":"Bash","tool_input":{"command":"git reset --hard=no"}}'

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
t "push -u (f in name)" ask  '{"tool_name":"Bash","tool_input":{"command":"git push -u origin x-of-tag"}}'
t "--force-with-lease"  ask   '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin feature"}}'

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

echo "--- block: with git global flags between git and subcommand ---"
t "-c key=val push -f"                block '{"tool_name":"Bash","tool_input":{"command":"git -c user.name=x push -f origin main"}}'
t "--git-dir=PATH push --force"       block '{"tool_name":"Bash","tool_input":{"command":"git --git-dir=/tmp/repo/.git push --force origin main"}}'
t "--git-dir PATH push --force"       block '{"tool_name":"Bash","tool_input":{"command":"git --git-dir /tmp/repo/.git push --force origin main"}}'
t "-P push --force"                   block '{"tool_name":"Bash","tool_input":{"command":"git -P push --force origin main"}}'
t "-C path clean -f"                  block '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo clean -f"}}'
t "-C path branch -D"                 block '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo branch -D feature"}}'
t "-C path checkout ."                block '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo checkout ."}}'
t "-C path restore ."                 block '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo restore ."}}'
t "-C path stash drop"                block '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo stash drop"}}'
t "-C path reflog expire"             block '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo reflog expire --all"}}'

echo "--- block: quoted values containing spaces ---"
t '-C "/path with spaces" push --force'   block '{"tool_name":"Bash","tool_input":{"command":"git -C \"/tmp/has space\" push --force"}}'
t '-c "key=val w/ space" push --force'    block '{"tool_name":"Bash","tool_input":{"command":"git -c \"http.extraHeader=Authorization x\" push --force"}}'
echo "--- ask: with git global flags between git and subcommand ---"
t "-C path checkout -- file"          ask   '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo checkout -- src/main.rs"}}'
t "-C path push"                      ask   '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo push"}}'
t "-C path push --force-with-lease"   ask   '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo push --force-with-lease"}}'
t "-C path reset --hard"              ask   '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo reset --hard"}}'
t '-C "/with space" reset --hard'     ask   '{"tool_name":"Bash","tool_input":{"command":"git -C \"/tmp/has space\" reset --hard"}}'
t "-C '/space' push --force-with-lease" ask '{"tool_name":"Bash","tool_input":{"command":"git -C '"'"'/tmp/has space'"'"' push --force-with-lease"}}'
t "-C path commit -m x"               ask   '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo commit -m hi"}}'
t "-C path stash"                     ask   '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo stash"}}'

echo "--- allow: stage manipulation with git global flags ---"
t "-c key=val add ."                  allow '{"tool_name":"Bash","tool_input":{"command":"git -c user.name=x add ."}}'
t "-C path rm file"                   allow '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo rm README.md"}}'
t "-C path rm --cached file"          allow '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo rm --cached secret.txt"}}'

echo "--- allow: not git ---"
t "non-git command"     allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
t "empty command"       allow '{"tool_name":"Bash","tool_input":{"command":""}}'
t "git in string"       allow '{"tool_name":"Bash","tool_input":{"command":"echo git is great"}}'
t "Write tool"          allow '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'
t "Read tool"           allow '{"tool_name":"Read","tool_input":{"file_path":"test.txt"}}'
t "Edit tool"           allow '{"tool_name":"Edit","tool_input":{"file_path":"test.txt"}}'

print_results
