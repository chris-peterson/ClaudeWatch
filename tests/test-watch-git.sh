#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../watches/watch-git.yml"
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
# git accepts any unique prefix of a long option; each of these deletes.
t "--force"             block '{"tool_name":"Bash","tool_input":{"command":"git clean --force"}}'
t "-d --force"          block '{"tool_name":"Bash","tool_input":{"command":"git clean -d --force"}}'
t "--f (prefix)"        block '{"tool_name":"Bash","tool_input":{"command":"git clean --f"}}'
t "--forc (prefix)"     block '{"tool_name":"Bash","tool_input":{"command":"git clean --forc -d"}}'
t "--format-like word"  allow '{"tool_name":"Bash","tool_input":{"command":"git clean -n --foo"}}'

echo "--- block: stash drop/clear ---"
t "drop"                block '{"tool_name":"Bash","tool_input":{"command":"git stash drop stash@{0}"}}'
t "clear"               block '{"tool_name":"Bash","tool_input":{"command":"git stash clear"}}'

echo "--- block: reflog expire/delete ---"
t "expire"              block '{"tool_name":"Bash","tool_input":{"command":"git reflog expire --expire=now --all"}}'
t "delete"              block '{"tool_name":"Bash","tool_input":{"command":"git reflog delete HEAD@{2}"}}'

echo "--- block: gc --prune=now / prune ---"
t "gc --prune=now"      block '{"tool_name":"Bash","tool_input":{"command":"git gc --prune=now"}}'
t "gc --aggressive --prune=all" block '{"tool_name":"Bash","tool_input":{"command":"git gc --aggressive --prune=all"}}'
t "gc --prune now"      block '{"tool_name":"Bash","tool_input":{"command":"git gc --prune now"}}'
t "prune"               block '{"tool_name":"Bash","tool_input":{"command":"git prune"}}'
t "prune --expire=now"  block '{"tool_name":"Bash","tool_input":{"command":"git prune --expire=now"}}'
t "prune -n (dry run)"  allow '{"tool_name":"Bash","tool_input":{"command":"git prune -n"}}'
t "gc (default)"        allow '{"tool_name":"Bash","tool_input":{"command":"git gc"}}'
t "remote prune"        allow '{"tool_name":"Bash","tool_input":{"command":"git remote prune origin"}}'
t "worktree prune"      allow '{"tool_name":"Bash","tool_input":{"command":"git worktree prune"}}'
t "fetch --prune"       allow '{"tool_name":"Bash","tool_input":{"command":"git fetch --prune"}}'
t "prune-packed"        allow '{"tool_name":"Bash","tool_input":{"command":"git prune-packed"}}'

echo "--- block: filter-branch / filter-repo ---"
t "filter-branch"       block '{"tool_name":"Bash","tool_input":{"command":"git filter-branch --tree-filter \"rm -f secrets.txt\" -- --all"}}'
t "filter-repo"         block '{"tool_name":"Bash","tool_input":{"command":"git filter-repo --path secrets.txt --invert-paths"}}'
t "-C path filter-repo" block '{"tool_name":"Bash","tool_input":{"command":"git -C build filter-repo --force"}}'
t "filter-repo --analyze" allow '{"tool_name":"Bash","tool_input":{"command":"git filter-repo --analyze"}}'
t "filter-repo --dry-run" allow '{"tool_name":"Bash","tool_input":{"command":"git filter-repo --path secrets.txt --invert-paths --dry-run"}}'
t "filter-branch --help" allow '{"tool_name":"Bash","tool_input":{"command":"git filter-branch --help"}}'

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
t "reset --h (prefix)"  ask   '{"tool_name":"Bash","tool_input":{"command":"git reset --h"}}'
t "reset --har HEAD~1"  ask   '{"tool_name":"Bash","tool_input":{"command":"git reset --har HEAD~1"}}'
t "reset --help"        allow '{"tool_name":"Bash","tool_input":{"command":"git reset --help"}}'
t "reset --hardware (not a prefix)" allow '{"tool_name":"Bash","tool_input":{"command":"git reset --hardware"}}'

echo "--- ask: commit ---"
t "commit -m"           ask   '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: update readme\""}}'
t "commit -F file"      ask   '{"tool_name":"Bash","tool_input":{"command":"git commit -F /tmp/msg.txt"}}'
# The shell runs a `$(…)` inside double quotes, so a heredoc message is a
# compound command ([OUT-08]).
t "heredoc commit (compound → block)" block '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(cat <<'"'"'EOF'"'"'\nfix\nEOF\n)\""}}'
# Compound command: the commit ask is escalated to a block (a host allow list
# could auto-approve `git add` + `git commit` segment-by-segment, skipping the
# confirm). See the compound-command escalation tests in test-engine.sh.
t "add && commit (compound → block)" block '{"tool_name":"Bash","tool_input":{"command":"git add . && git commit -m \"test\""}}'

echo "--- ask: stash ---"
t "stash"               ask   '{"tool_name":"Bash","tool_input":{"command":"git stash"}}'
t "stash pop"           ask   '{"tool_name":"Bash","tool_input":{"command":"git stash pop"}}'
t "stash push -m"       ask   '{"tool_name":"Bash","tool_input":{"command":"git stash push -m wip"}}'
t "stash apply"         ask   '{"tool_name":"Bash","tool_input":{"command":"git stash apply stash@{1}"}}'
t "stash list"          allow '{"tool_name":"Bash","tool_input":{"command":"git stash list"}}'
t "stash list --stat"   allow '{"tool_name":"Bash","tool_input":{"command":"git stash list --stat"}}'
t "stash show"          allow '{"tool_name":"Bash","tool_input":{"command":"git stash show"}}'
t "stash show -p ref"   allow '{"tool_name":"Bash","tool_input":{"command":"git stash show -p stash@{0}"}}'
t "-C path stash list"  allow '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo stash list"}}'
t "stash listing (not list)" ask '{"tool_name":"Bash","tool_input":{"command":"git stash listing"}}'
# A read-only stash ahead of a mutating one must not exempt the chain.
t "stash list; stash pop (compound → block)" block '{"tool_name":"Bash","tool_input":{"command":"git stash list; git stash pop"}}'

echo "--- ask: branch -D (recoverable via reflog) ---"
t "-D"                  ask   '{"tool_name":"Bash","tool_input":{"command":"git branch -D unmerged-feature"}}'
t "-d (lowercase)"      allow '{"tool_name":"Bash","tool_input":{"command":"git branch -d merged-feature"}}'
# -d with force deletes an unmerged branch, the same as -D.
t "-d -f"               ask   '{"tool_name":"Bash","tool_input":{"command":"git branch -d -f unmerged-feature"}}'
t "-df"                 ask   '{"tool_name":"Bash","tool_input":{"command":"git branch -df unmerged-feature"}}'
t "--delete --force"    ask   '{"tool_name":"Bash","tool_input":{"command":"git branch --delete --force unmerged-feature"}}'
t "--d --forc (prefixes)" ask '{"tool_name":"Bash","tool_input":{"command":"git branch --d --forc unmerged-feature"}}'
t "--delete (no force)" allow '{"tool_name":"Bash","tool_input":{"command":"git branch --delete merged-feature"}}'
t "-f (create, no delete)" allow '{"tool_name":"Bash","tool_input":{"command":"git branch -f topic HEAD~1"}}'

echo "--- ask: push ---"
t "push"                ask   '{"tool_name":"Bash","tool_input":{"command":"git push"}}'
t "push origin"         ask   '{"tool_name":"Bash","tool_input":{"command":"git push origin feature-branch"}}'
t "push -u"             ask   '{"tool_name":"Bash","tool_input":{"command":"git push -u origin main"}}'
t "push -u (f in name)" ask  '{"tool_name":"Bash","tool_input":{"command":"git push -u origin x-of-tag"}}'
t "--force-with-lease"  ask   '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin feature"}}'
t "push src:dst (normal refspec)" ask '{"tool_name":"Bash","tool_input":{"command":"git push origin main:main"}}'

echo "--- ask: push --delete (remote branch delete) ---"
t "--delete"            ask   '{"tool_name":"Bash","tool_input":{"command":"git push origin --delete docs-pages-preview"}}'
t "-d (short)"          ask   '{"tool_name":"Bash","tool_input":{"command":"git push -d origin feature"}}'
t ":branch (colon refspec)" ask '{"tool_name":"Bash","tool_input":{"command":"git push origin :feature"}}'
t "--del (prefix)"      ask   '{"tool_name":"Bash","tool_input":{"command":"git push origin --del feature"}}'

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
t "-C path branch -D"                 ask   '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo branch -D feature"}}'
t "-C path push --delete"             ask   '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo push origin --delete feature"}}'
t "-C path reset --hard"              ask   '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo reset --hard"}}'
t '-C "/with space" reset --hard'     ask   '{"tool_name":"Bash","tool_input":{"command":"git -C \"/tmp/has space\" reset --hard"}}'
t "-C '/space' push --force-with-lease" ask '{"tool_name":"Bash","tool_input":{"command":"git -C '"'"'/tmp/has space'"'"' push --force-with-lease"}}'
t "-C path commit -m x"               ask   '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo commit -m hi"}}'
t "-C path stash"                     ask   '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo stash"}}'

echo "--- allow: stage manipulation with git global flags ---"
t "-c key=val add ."                  allow '{"tool_name":"Bash","tool_input":{"command":"git -c user.name=x add ."}}'
t "-C path rm file"                   allow '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo rm README.md"}}'
t "-C path rm --cached file"          allow '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo rm --cached secret.txt"}}'

echo "--- verb boundary: a shell separator ends the subcommand ---"
# A guarded subcommand with no arguments is followed by whatever comes next in
# the shell, not by whitespace. Each of these three patterns is edited
# separately, so each is asserted; one separator stands for the rest.
t "(commit)"            block '{"tool_name":"Bash","tool_input":{"command":"(git commit)"}}'
t "(push)"              block '{"tool_name":"Bash","tool_input":{"command":"(git push)"}}'
t "(stash)"             block '{"tool_name":"Bash","tool_input":{"command":"(git stash)"}}'
t "commit;"             block '{"tool_name":"Bash","tool_input":{"command":"git commit;echo done"}}'
t "\`stash\`"           block '{"tool_name":"Bash","tool_input":{"command":"echo `git stash`"}}'
t "(checkout .)"        block '{"tool_name":"Bash","tool_input":{"command":"(git checkout .)"}}'
t "checkout .;"         block '{"tool_name":"Bash","tool_input":{"command":"git checkout .;echo done"}}'
t "(restore .)"         block '{"tool_name":"Bash","tool_input":{"command":"(git restore .)"}}'
# A hyphen continues the subcommand rather than ending it, and a closing quote
# does not end it at all — a pattern mentioning the command is not the command.
t "commit-tree"         allow '{"tool_name":"Bash","tool_input":{"command":"git commit-tree HEAD"}}'
t "grep for push"       allow '{"tool_name":"Bash","tool_input":{"command":"grep -rn '"'"'git push'"'"' . | head -20"}}'
t "sed for commit"      allow '{"tool_name":"Bash","tool_input":{"command":"git log | grep '"'"'git commit'"'"'"}}'

echo "--- allow: not git ---"
t "non-git command"     allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
t "empty command"       allow '{"tool_name":"Bash","tool_input":{"command":""}}'
t "git in string"       allow '{"tool_name":"Bash","tool_input":{"command":"echo git is great"}}'
t "Write tool"          allow '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'
t "Read tool"           allow '{"tool_name":"Read","tool_input":{"file_path":"test.txt"}}'
t "Edit tool"           allow '{"tool_name":"Edit","tool_input":{"file_path":"test.txt"}}'

print_results
