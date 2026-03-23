#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../rules/watch-secrets.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-secrets ==="

echo "--- block: cat SSH private keys ---"
t "cat ~/.ssh/id_rsa"     block '{"tool_name":"Bash","tool_input":{"command":"cat ~/.ssh/id_rsa"}}'
t "cat ~/.ssh/id_ed25519" block '{"tool_name":"Bash","tool_input":{"command":"cat ~/.ssh/id_ed25519"}}'
t "cat /home/user/.ssh/id_rsa" block '{"tool_name":"Bash","tool_input":{"command":"cat /home/user/.ssh/id_rsa"}}'

echo "--- block: cat cloud credentials ---"
t "cat .aws/credentials"  block '{"tool_name":"Bash","tool_input":{"command":"cat ~/.aws/credentials"}}'
t "cat .config/gcloud"    block '{"tool_name":"Bash","tool_input":{"command":"cat ~/.config/gcloud/credentials.json"}}'

echo "--- block: expose secrets ---"
t "echo SECRET_KEY"        block '{"tool_name":"Bash","tool_input":{"command":"echo $SECRET_KEY"}}'
t "echo API_KEY"           block '{"tool_name":"Bash","tool_input":{"command":"echo $API_KEY"}}'
t "printf PASSWORD"        block '{"tool_name":"Bash","tool_input":{"command":"printf \"%s\" $PASSWORD"}}'
t "cat credentials.json"   block '{"tool_name":"Bash","tool_input":{"command":"cat /app/credentials.json"}}'
t "head token file"        block '{"tool_name":"Bash","tool_input":{"command":"head ~/.netrc_token"}}'

echo "--- block: export secrets inline ---"
t "export SECRET_KEY="    block '{"tool_name":"Bash","tool_input":{"command":"export SECRET_KEY=abc123"}}'
t "export API_KEY="       block '{"tool_name":"Bash","tool_input":{"command":"export API_KEY=sk-12345"}}'
t "export DATABASE_URL="  block '{"tool_name":"Bash","tool_input":{"command":"export DATABASE_URL=postgres://user:pass@host/db"}}'

echo "--- block: cat .env files ---"
t "cat .env"              block '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}'
t "cat .env.local"        block '{"tool_name":"Bash","tool_input":{"command":"cat .env.local"}}'

echo "--- block: cat PEM/key files ---"
t "cat server.pem"        block '{"tool_name":"Bash","tool_input":{"command":"cat server.pem"}}'
t "cat private.key"       block '{"tool_name":"Bash","tool_input":{"command":"cat private.key"}}'

echo "--- block: env / printenv ---"
t "env"                   block '{"tool_name":"Bash","tool_input":{"command":"env"}}'
t "printenv"              block '{"tool_name":"Bash","tool_input":{"command":"printenv"}}'

echo "--- ask: cat dotfiles ---"
t "cat ~/.bashrc"         ask   '{"tool_name":"Bash","tool_input":{"command":"cat ~/.bashrc"}}'
t "cat ~/.gitconfig"      ask   '{"tool_name":"Bash","tool_input":{"command":"cat ~/.gitconfig"}}'

echo "--- allow: safe operations ---"
t "cat normal file"       allow '{"tool_name":"Bash","tool_input":{"command":"cat README.md"}}'
t "echo normal string"    allow '{"tool_name":"Bash","tool_input":{"command":"echo hello world"}}'
t "ls -la"                allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
t "Write tool"            allow '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'

print_results
