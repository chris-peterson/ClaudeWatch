#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../watches/watch-host.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-host ==="

echo "--- block: shutdown / reboot ---"
t "shutdown -h now"      block '{"tool_name":"Bash","tool_input":{"command":"shutdown -h now"}}'
t "sudo reboot"          block '{"tool_name":"Bash","tool_input":{"command":"sudo reboot"}}'
t "/sbin/halt"           block '{"tool_name":"Bash","tool_input":{"command":"/sbin/halt"}}'
t "poweroff"             block '{"tool_name":"Bash","tool_input":{"command":"poweroff"}}'
t "systemctl reboot"     block '{"tool_name":"Bash","tool_input":{"command":"systemctl reboot"}}'
t "systemctl poweroff"   block '{"tool_name":"Bash","tool_input":{"command":"systemctl --no-wall poweroff"}}'
t "make && reboot"       block '{"tool_name":"Bash","tool_input":{"command":"make install && reboot"}}'
t "shutdown -c (cancel)" allow '{"tool_name":"Bash","tool_input":{"command":"shutdown -c"}}'
t "shutdown --help" allow '{"tool_name":"Bash","tool_input":{"command":"shutdown --help"}}'
t "systemctl --dry-run poweroff" allow '{"tool_name":"Bash","tool_input":{"command":"systemctl --dry-run poweroff"}}'

echo "--- block: crontab -r ---"
t "crontab -r"           block '{"tool_name":"Bash","tool_input":{"command":"crontab -r"}}'
t "crontab -u root -r"   block '{"tool_name":"Bash","tool_input":{"command":"crontab -u deploy -r"}}'
t "crontab -ir"          block '{"tool_name":"Bash","tool_input":{"command":"crontab -ir"}}'

echo "--- block: fork bomb ---"
t ":(){ :|:& };:"        block '{"tool_name":"Bash","tool_input":{"command":":(){ :|:& };:"}}'
t "named bomb pipe"      block '{"tool_name":"Bash","tool_input":{"command":"bomb(){ bomb|bomb& }; bomb"}}'
t "named bomb &&"        block '{"tool_name":"Bash","tool_input":{"command":"bomb(){ bomb& bomb& }; bomb"}}'

echo "--- allow: the words as data, and safe forms ---"
t "grep shutdown"        allow '{"tool_name":"Bash","tool_input":{"command":"grep -rn shutdown src/"}}'
t "echo reboot"          allow '{"tool_name":"Bash","tool_input":{"command":"echo \"reboot required\""}}'
t "graceful-shutdown"    allow '{"tool_name":"Bash","tool_input":{"command":"npm run graceful-shutdown"}}'
t "systemctl status"     allow '{"tool_name":"Bash","tool_input":{"command":"systemctl status nginx"}}'
t "systemctl restart svc" allow '{"tool_name":"Bash","tool_input":{"command":"systemctl restart nginx"}}'
t "crontab -l"           allow '{"tool_name":"Bash","tool_input":{"command":"crontab -l"}}'
t "crontab -l | grep -r" allow '{"tool_name":"Bash","tool_input":{"command":"crontab -l | grep -rn x"}}'
t "ordinary function"    allow '{"tool_name":"Bash","tool_input":{"command":"greet(){ echo hi; }; greet"}}'
t "recursive function"   allow '{"tool_name":"Bash","tool_input":{"command":"f(){ f; }"}}'

print_results
