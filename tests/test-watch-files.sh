#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../rules/watch-files.yml"
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

echo "--- allow: safe operations ---"
t "rm single file"   allow '{"tool_name":"Bash","tool_input":{"command":"rm temp.txt"}}'
t "mv local"         allow '{"tool_name":"Bash","tool_input":{"command":"mv old.txt new.txt"}}'
t "ls -la"           allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
t "Write tool"       allow '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'

print_results
