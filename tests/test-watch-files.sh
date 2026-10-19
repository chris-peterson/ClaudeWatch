#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../watches/watch-files.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-files ==="

echo "--- block: rm -rf / ---"
t "rm -rf /"         block '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
t "rm -fr /"         block '{"tool_name":"Bash","tool_input":{"command":"rm -fr /"}}'
t "rm -rf /*"        block '{"tool_name":"Bash","tool_input":{"command":"rm -rf /*"}}'
# Recursive and force are read as independent options, so every spelling of the
# pair reaches the rule: clustered, split, reordered, long, and the `-R` synonym.
t "rm -r -f /"       block '{"tool_name":"Bash","tool_input":{"command":"rm -r -f /"}}'
t "rm --long /"      block '{"tool_name":"Bash","tool_input":{"command":"rm --recursive --force /"}}'
t "rm --long rev /"  block '{"tool_name":"Bash","tool_input":{"command":"rm --force --recursive /"}}'
t "rm mixed /"       block '{"tool_name":"Bash","tool_input":{"command":"rm -r --force /"}}'
t "rm -Rf /"         block '{"tool_name":"Bash","tool_input":{"command":"rm -Rf /"}}'
t "rm -R --force /"  block '{"tool_name":"Bash","tool_input":{"command":"rm -R --force /"}}'
t "rm -Rf /*"        block '{"tool_name":"Bash","tool_input":{"command":"rm -Rf /*"}}'
t "(rm --long /)"    block '{"tool_name":"Bash","tool_input":{"command":"(rm --recursive --force /)"}}'

echo "--- allow: rm near misses ---"
# Force alone is not recursive; `rm` is bounded as its own shell word; and the
# root tail takes `/` and `/*` without reaching a path or a scoped glob.
t "rm --force file"  allow '{"tool_name":"Bash","tool_input":{"command":"rm --force notes.txt"}}'
t "confirm -rf /"    allow '{"tool_name":"Bash","tool_input":{"command":"confirm -rf /"}}'
t "my-rm -rf /"      allow '{"tool_name":"Bash","tool_input":{"command":"my-rm -rf /"}}'
t "rm -rf /*.log"    ask   '{"tool_name":"Bash","tool_input":{"command":"rm -rf /*.log"}}'
t "git rm --cached"  allow '{"tool_name":"Bash","tool_input":{"command":"git rm --cached -r .claude/skills"}}'
t "grep for rm -rf /" allow '{"tool_name":"Bash","tool_input":{"command":"grep -rn '"'"'rm -rf /'"'"' ."}}'

echo "--- rm opening a quoted -c or eval script (#42) ---"
# A quote is a boundary only where it opens a script the shell runs, so the
# rm that starts one is matched and an rm that starts a search pattern is not.
t "bash -c rm -rf /"           block '{"tool_name":"Bash","tool_input":{"command":"bash -c \"rm -rf /\""}}'
t "sh -c rm -rf /"             block '{"tool_name":"Bash","tool_input":{"command":"sh -c '"'"'rm -rf /'"'"'"}}'
t "bash -lc rm -rf /"          block '{"tool_name":"Bash","tool_input":{"command":"bash -lc '"'"'rm -rf /'"'"'"}}'
t "/bin/bash -c rm -rf /"      block '{"tool_name":"Bash","tool_input":{"command":"/bin/bash -c \"rm -rf /\""}}'
t "zsh -c rm -rf /"            block '{"tool_name":"Bash","tool_input":{"command":"zsh -c \"rm -rf /\""}}'
t "bash -x -c rm -rf /"        block '{"tool_name":"Bash","tool_input":{"command":"bash -x -c '"'"'rm -rf /'"'"'"}}'
t "grep -c for rm -rf /"       allow '{"tool_name":"Bash","tool_input":{"command":"grep -c '"'"'rm -rf /'"'"' file"}}'
t "a word ending in sh -c"     allow '{"tool_name":"Bash","tool_input":{"command":"myfish -c '"'"'rm -rf /'"'"'"}}'
t "eval rm -rf /"              block '{"tool_name":"Bash","tool_input":{"command":"eval \"rm -rf /\""}}'
t "bash -c rm -rf ~/Documents" ask   '{"tool_name":"Bash","tool_input":{"command":"bash -c \"rm -rf ~/Documents\""}}'
t "eval rm -rf ~/Documents"    ask   '{"tool_name":"Bash","tool_input":{"command":"eval \"rm -rf ~/Documents\""}}'
t "bash -c cd; rm -rf"         ask   '{"tool_name":"Bash","tool_input":{"command":"bash -c \"cd /x; rm -rf ~/Documents\""}}'
t "bash -c rm -r"              ask   '{"tool_name":"Bash","tool_input":{"command":"bash -c \"rm -r ~/Documents\""}}'
t "my-eval is not eval"        allow '{"tool_name":"Bash","tool_input":{"command":"my-eval \"rm -rf ~/Documents\""}}'

echo "--- block: chmod 777 ---"
t "chmod 777"        block '{"tool_name":"Bash","tool_input":{"command":"chmod 777 /tmp/file"}}'
t "chmod -R 777"     block '{"tool_name":"Bash","tool_input":{"command":"chmod -R 777 /var/www"}}'

echo "--- block: mv to /dev/null ---"
t "mv /dev/null"     block '{"tool_name":"Bash","tool_input":{"command":"mv important.log /dev/null"}}'

echo "--- block: shred ---"
t "shred file"       block '{"tool_name":"Bash","tool_input":{"command":"shred secret.key"}}'

echo "--- ask: rm -rf ---"
t "rm -rf dir"       ask   '{"tool_name":"Bash","tool_input":{"command":"rm -rf ./build"}}'
t "rm -rf node_modules" ask '{"tool_name":"Bash","tool_input":{"command":"rm -rf node_modules"}}'

echo "--- ask: rm -r ---"
t "rm -r dir"        ask   '{"tool_name":"Bash","tool_input":{"command":"rm -r old-dir"}}'

echo "--- ask: mv / ---"
t "mv /etc"          ask   '{"tool_name":"Bash","tool_input":{"command":"mv /etc/config /etc/config.bak"}}'

echo "--- ask: chmod ---"
t "chmod 644"        ask   '{"tool_name":"Bash","tool_input":{"command":"chmod 644 readme.md"}}'
t "chmod -R 755"     ask   '{"tool_name":"Bash","tool_input":{"command":"chmod -R 755 ./dist"}}'

echo "--- ask: chown ---"
t "chown user"       ask   '{"tool_name":"Bash","tool_input":{"command":"chown www-data:www-data index.html"}}'
t "sudo chown -R root" ask '{"tool_name":"Bash","tool_input":{"command":"sudo chown -R root /opt"}}'

echo "--- except: cache/temp file deletion ---"
t "rm -rf cache dir"    allow '{"tool_name":"Bash","tool_input":{"command":"rm -rf ~/.cache/pip"}}'
t "rm -rf /tmp"         allow '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/build-output"}}'
# The exemption's own flag run takes long options too, or the same delete
# prompts when it's spelled out.
t "rm --long /tmp"      allow '{"tool_name":"Bash","tool_input":{"command":"rm --recursive --force /tmp/build-output"}}'
t "rm -r /var/tmp"      allow '{"tool_name":"Bash","tool_input":{"command":"rm -r /var/tmp/stale-dir"}}'

echo "--- scratch exemption reads every target (#35) ---"
# One row per case in #35, run with cwd /work/repo.
c() { t "$1" "$2" '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"'"$3"'"}}'; }
c "rm -rf \$(mktemp -d)"            block 'rm -rf $(mktemp -d)'
c "rm -rf \"\$(mktemp -d)\""        block 'rm -rf \"$(mktemp -d)\"'
c "rm -rf /tmp/\$(whoami)"          block 'rm -rf /tmp/$(whoami)'
c "rm -rf /tmp/../Users/foo"        ask   'rm -rf /tmp/../Users/foo'
c "scratch then out of tree"        ask   'rm -rf /tmp/build /Users/foo/Documents'
c "out of tree then scratch"        ask   'rm -rf /Users/foo/Documents /tmp/build'
c "in-tree then scratch"            allow 'rm -rf /work/repo/bin /tmp/build'
c "scratch then in-tree"            allow 'rm -rf /tmp/build bin'
c "rm -rf /private/tmp/build"       allow 'rm -rf /private/tmp/build'
c "rm -r /private/var/tmp"          allow 'rm -r /private/var/tmp/stale-dir'
c "rm -rf /etc/foo"                 ask   'rm -rf /etc/foo'
c "rm -rf /tmp/build"               allow 'rm -rf /tmp/build'
c "tool dir then scratch"           allow 'rm -rf .pytest_cache /tmp/build'

echo "--- is_in_project_tree: in-tree recursive deletes allowed ---"
t "rm -r in-tree relative"       allow '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r old-dir"}}'
t "rm -rf in-tree relative dir"  allow '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -rf src/legacy"}}'
t "rm -r in-tree dotted path"    allow '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r ./build"}}'
t "rm -rf in-tree absolute"      allow '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -rf /work/repo/build"}}'
t "rm -r quoted in-tree path"    allow '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r \"my dir\""}}'
t "rm -r multiple in-tree"       allow '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r a b c"}}'

echo "--- is_in_project_tree: out-of-tree / unresolvable still prompts ---"
t "rm -r out-of-tree absolute"   ask   '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r /etc/foo"}}'
t "rm -r parent escape"          ask   '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r ../sibling"}}'
t "rm -rf home path"             ask   '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -rf ~/Downloads/x"}}'
t "rm -r cwd itself"             ask   '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r ."}}'
t "rm -rf .git directory"        ask   '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -rf .git"}}'
t "rm -rf inside .git"           ask   '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -rf .git/refs"}}'
t "rm -r glob target"            ask   '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r build/*"}}'
t "rm -r variable target"        ask   '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r $TMP"}}'
t "rm -r mixed in/out tree"      ask   '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r src /etc"}}'
t "rm -r in-tree, no cwd"        ask   '{"tool_name":"Bash","tool_input":{"command":"rm -r old-dir"}}'
t "rm -r escape via subpath .."  ask   '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r src/../../etc"}}'

echo "--- is_in_project_tree: project root anchors when cwd has moved ---"
export CLAUDE_PROJECT_DIR=/work/repo
t "rm -rf project-root absolute" allow '{"tool_name":"Bash","cwd":"/scratch/pad","tool_input":{"command":"rm -rf /work/repo/build"}}'
t "rm -r project root itself"    ask   '{"tool_name":"Bash","cwd":"/scratch/pad","tool_input":{"command":"rm -rf /work/repo"}}'
t "rm -rf .git under project"    ask   '{"tool_name":"Bash","cwd":"/scratch/pad","tool_input":{"command":"rm -rf /work/repo/.git"}}'
t "rm -r outside both roots"     ask   '{"tool_name":"Bash","cwd":"/scratch/pad","tool_input":{"command":"rm -r /etc/foo"}}'
unset CLAUDE_PROJECT_DIR
export CLAUDE_PROJECT_DIR=/
t "rm -rf project root is /"     ask   '{"tool_name":"Bash","tool_input":{"command":"rm -rf /etc/foo"}}'
unset CLAUDE_PROJECT_DIR

echo "--- is_ephemeral_scratch: regenerable tool output allowed from any cwd ---"
t "rm -rf playwright scratch"    allow '{"tool_name":"Bash","cwd":"/somewhere/else","tool_input":{"command":"rm -rf /work/repo/.playwright-mcp"}}'
t "rm -rf scratch, no cwd"       allow '{"tool_name":"Bash","tool_input":{"command":"rm -rf .playwright-mcp"}}'
t "rm -r pycache"                allow '{"tool_name":"Bash","tool_input":{"command":"rm -r /work/repo/__pycache__"}}'
t "rm -rf several scratch dirs"  allow '{"tool_name":"Bash","tool_input":{"command":"rm -rf .pytest_cache .mypy_cache"}}'

echo "--- is_ephemeral_scratch: anything else still prompts ---"
t "rm -rf scratch plus source"   ask   '{"tool_name":"Bash","tool_input":{"command":"rm -rf .playwright-mcp /etc/foo"}}'
t "rm -rf inside scratch dir"    ask   '{"tool_name":"Bash","tool_input":{"command":"rm -rf /work/repo/.playwright-mcp/traces"}}'
t "rm -rf scratch-like name"     ask   '{"tool_name":"Bash","tool_input":{"command":"rm -rf /work/repo/playwright-mcp"}}'
t "rm -rf scratch under glob"    ask   '{"tool_name":"Bash","tool_input":{"command":"rm -rf */.playwright-mcp"}}'

echo "--- is_ephemeral_scratch: compound scratch delete escalates to block ---"
t "rm -rf scratch chained"       block '{"tool_name":"Bash","tool_input":{"command":"rm -rf .playwright-mcp && echo done"}}'

echo "--- is_in_project_tree: compound in-tree delete escalates to block ---"
t "rm -r in-tree chained"        block '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r src && echo done"}}'

echo "--- allow: safe operations ---"
t "rm single file"   allow '{"tool_name":"Bash","tool_input":{"command":"rm temp.txt"}}'
t "mv local"         allow '{"tool_name":"Bash","tool_input":{"command":"mv old.txt new.txt"}}'
t "ls -la"           allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
t "Write tool"       allow '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'

print_results
