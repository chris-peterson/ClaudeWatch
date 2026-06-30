#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../watches/watch-files.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-files ==="

echo "--- block: rm -rf / ---"
t "rm -rf /"         block '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
t "rm -fr /"         block '{"tool_name":"Bash","tool_input":{"command":"rm -fr /"}}'
t "rm -rf /*"        block '{"tool_name":"Bash","tool_input":{"command":"rm -rf /*"}}'

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
t "rm -r /var/tmp"      allow '{"tool_name":"Bash","tool_input":{"command":"rm -r /var/tmp/stale-dir"}}'

echo "--- is_relative_to_cwd: in-tree recursive deletes allowed ---"
t "rm -r in-tree relative"       allow '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r old-dir"}}'
t "rm -rf in-tree relative dir"  allow '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -rf src/legacy"}}'
t "rm -r in-tree dotted path"    allow '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r ./build"}}'
t "rm -rf in-tree absolute"      allow '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -rf /work/repo/build"}}'
t "rm -r quoted in-tree path"    allow '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r \"my dir\""}}'
t "rm -r multiple in-tree"       allow '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r a b c"}}'

echo "--- is_relative_to_cwd: out-of-tree / unresolvable still prompts ---"
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

echo "--- is_relative_to_cwd: compound in-tree delete escalates to block ---"
t "rm -r in-tree chained"        block '{"tool_name":"Bash","cwd":"/work/repo","tool_input":{"command":"rm -r src && echo done"}}'

echo "--- allow: safe operations ---"
t "rm single file"   allow '{"tool_name":"Bash","tool_input":{"command":"rm temp.txt"}}'
t "mv local"         allow '{"tool_name":"Bash","tool_input":{"command":"mv old.txt new.txt"}}'
t "ls -la"           allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
t "Write tool"       allow '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'

print_results
