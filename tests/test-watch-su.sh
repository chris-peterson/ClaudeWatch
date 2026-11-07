#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../watches/watch-su.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-su ==="

echo "--- block: sudo ---"
t "sudo cmd"             block '{"tool_name":"Bash","tool_input":{"command":"sudo pip install flask"}}'
t "sudo -n"              block '{"tool_name":"Bash","tool_input":{"command":"sudo -n true"}}'
t "sudo -u user"         block '{"tool_name":"Bash","tool_input":{"command":"sudo -u postgres psql"}}'
t "sudo apt-get"         block '{"tool_name":"Bash","tool_input":{"command":"sudo apt-get install -y jq"}}'
t "/usr/bin/sudo"        block '{"tool_name":"Bash","tool_input":{"command":"/usr/bin/sudo ls /root"}}'
t "VAR= sudo"            block '{"tool_name":"Bash","tool_input":{"command":"DEBIAN_FRONTEND=noninteractive sudo apt install jq"}}'
t "xargs sudo"           block '{"tool_name":"Bash","tool_input":{"command":"echo /x | xargs sudo rm"}}'
t "chained sudo"         block '{"tool_name":"Bash","tool_input":{"command":"make && sudo make install"}}'
t "bash -c sudo"         block '{"tool_name":"Bash","tool_input":{"command":"bash -c \"sudo ls\""}}'

echo "--- block: su ---"
t "su"                   block '{"tool_name":"Bash","tool_input":{"command":"su"}}'
t "su -"                 block '{"tool_name":"Bash","tool_input":{"command":"su - root"}}'
t "su -c"                block '{"tool_name":"Bash","tool_input":{"command":"su -c \"whoami\" deploy"}}'
t "sudo su"              block '{"tool_name":"Bash","tool_input":{"command":"sudo su"}}'

echo "--- allow: the word as data, or a longer name ---"
t "grep sudo"            allow '{"tool_name":"Bash","tool_input":{"command":"grep -rn sudo scripts/"}}'
t "echo quoted sudo"     allow '{"tool_name":"Bash","tool_input":{"command":"echo \"needs sudo to install\""}}'
t "man sudo"             allow '{"tool_name":"Bash","tool_input":{"command":"man sudo"}}'
t "sudoedit-like name"   allow '{"tool_name":"Bash","tool_input":{"command":"sudo-prompt --help"}}'
t "subl"                 allow '{"tool_name":"Bash","tool_input":{"command":"subl README.md"}}'
t "git log --author su"  allow '{"tool_name":"Bash","tool_input":{"command":"git log --author su"}}'
t "path containing su"   allow '{"tool_name":"Bash","tool_input":{"command":"ls /opt/su/bin"}}'

print_results
