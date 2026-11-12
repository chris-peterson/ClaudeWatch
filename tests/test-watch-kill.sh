#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../watches/watch-kill.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-kill ==="

echo "--- ask: pkill ---"
t "pkill -f pattern"     ask   '{"tool_name":"Bash","tool_input":{"command":"pkill -f \"node server.js\""}}'
t "pkill name"           ask   '{"tool_name":"Bash","tool_input":{"command":"pkill vite"}}'
t "sudo pkill"           ask   '{"tool_name":"Bash","tool_input":{"command":"sudo pkill -9 nginx"}}'
t "/usr/bin/pkill"       ask   '{"tool_name":"Bash","tool_input":{"command":"/usr/bin/pkill vite"}}'
t "timeout 5 pkill"      ask   '{"tool_name":"Bash","tool_input":{"command":"timeout 5 pkill vite"}}'
t "bash -c pkill"        ask   '{"tool_name":"Bash","tool_input":{"command":"bash -c \"pkill vite\""}}'
t "(pkill) (subshell → block)" block '{"tool_name":"Bash","tool_input":{"command":"(pkill vite)"}}'
t "pkill;echo (compound → block)" block '{"tool_name":"Bash","tool_input":{"command":"pkill vite; echo done"}}'
t "chain → block"        block '{"tool_name":"Bash","tool_input":{"command":"npm run build && pkill -f vite"}}'

echo "--- ask: killall ---"
t "killall name"         ask   '{"tool_name":"Bash","tool_input":{"command":"killall node"}}'
t "killall -9"           ask   '{"tool_name":"Bash","tool_input":{"command":"killall -9 Finder"}}'
t "sudo killall"         ask   '{"tool_name":"Bash","tool_input":{"command":"sudo killall -HUP mDNSResponder"}}'
t "/usr/bin/killall"     ask   '{"tool_name":"Bash","tool_input":{"command":"/usr/bin/killall Dock"}}'
t "killall chained → block" block '{"tool_name":"Bash","tool_input":{"command":"killall node && npm start"}}'

echo "--- allow: pkill and killall as data, not a command ---"
t "grep killall"         allow '{"tool_name":"Bash","tool_input":{"command":"grep -rn killall scripts/"}}'
t "echo quoted killall"  allow '{"tool_name":"Bash","tool_input":{"command":"echo \"avoid killall here\""}}'
t "kill by pid"          allow '{"tool_name":"Bash","tool_input":{"command":"kill 12345"}}'
t "grep pkill"           allow '{"tool_name":"Bash","tool_input":{"command":"grep pkill notes.md"}}'
t "echo quoted pkill"    allow '{"tool_name":"Bash","tool_input":{"command":"echo \"use pkill carefully\""}}'
t "man pkill"            allow '{"tool_name":"Bash","tool_input":{"command":"man pkill"}}'
t "pgrep"                allow '{"tool_name":"Bash","tool_input":{"command":"pgrep -f vite"}}'
t "my-pkill"             allow '{"tool_name":"Bash","tool_input":{"command":"my-pkill vite"}}'

print_results
