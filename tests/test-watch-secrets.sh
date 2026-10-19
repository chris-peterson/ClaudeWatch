#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../watches/watch-secrets.yml"
t() { run_test "$RULES" "$@"; }
bash_input() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }

# Assert that a command asks and that the named rule is among the reasons.
asks_via() {
  local label="$1" rule="$2" command="$3" result
  TOTAL=$((TOTAL + 1))
  result=$(bash_input "$command" | python3 "$HOOK" "$RULES" 2>/dev/null || true)
  if echo "$result" | grep -q '"permissionDecision":"ask"' && echo "$result" | grep -qF -- "$rule:"; then
    PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $label"
  else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $label (expected ask via '$rule', got: ${result:-empty})"
  fi
}

echo "=== watch-secrets ==="

echo "--- block: read SSH private keys ---"
t "cat ~/.ssh/id_rsa"     block '{"tool_name":"Bash","tool_input":{"command":"cat ~/.ssh/id_rsa"}}'
t "cat ~/.ssh/id_ed25519" block '{"tool_name":"Bash","tool_input":{"command":"cat ~/.ssh/id_ed25519"}}'
t "cat /home/user/.ssh/id_rsa" block '{"tool_name":"Bash","tool_input":{"command":"cat /home/user/.ssh/id_rsa"}}'
t "tac ~/.ssh/id_rsa"     block '{"tool_name":"Bash","tool_input":{"command":"tac ~/.ssh/id_rsa"}}'
t "xxd ~/.ssh/id_rsa"     block '{"tool_name":"Bash","tool_input":{"command":"xxd ~/.ssh/id_rsa"}}'
t "/bin/cat ~/.ssh/id_rsa" block '{"tool_name":"Bash","tool_input":{"command":"/bin/cat ~/.ssh/id_rsa"}}'
t "bash -c 'cat key'"     block '{"tool_name":"Bash","tool_input":{"command":"bash -c '"'"'cat ~/.ssh/id_rsa'"'"'"}}'

echo "--- block: read cloud credentials ---"
t "cat .aws/credentials"  block '{"tool_name":"Bash","tool_input":{"command":"cat ~/.aws/credentials"}}'
t "cat .config/gcloud"    block '{"tool_name":"Bash","tool_input":{"command":"cat ~/.config/gcloud/credentials.json"}}'
t "head -n 5 credentials" block '{"tool_name":"Bash","tool_input":{"command":"head -n 5 ~/.aws/credentials"}}'
t "cat sso cache"         block '{"tool_name":"Bash","tool_input":{"command":"cat ~/.aws/sso/cache/0123abcd.json"}}'
t "bat cli cache"         block '{"tool_name":"Bash","tool_input":{"command":"bat ~/.aws/cli/cache/0123abcd.json"}}'

echo "--- block: a bare < redirect names the file with no reader ---"
t "< ~/.aws/credentials"  block '{"tool_name":"Bash","tool_input":{"command":"< ~/.aws/credentials"}}'
t "<~/.aws/credentials"   block '{"tool_name":"Bash","tool_input":{"command":"<~/.aws/credentials"}}'
t "wc -l < credentials"   block '{"tool_name":"Bash","tool_input":{"command":"wc -l < ~/.aws/credentials"}}'
t "0< ~/.ssh/id_rsa"      block '{"tool_name":"Bash","tool_input":{"command":"0< ~/.ssh/id_rsa"}}'
t "done < ~/.ssh/id_rsa"  block '{"tool_name":"Bash","tool_input":{"command":"while read l; do echo $l; done < ~/.ssh/id_rsa"}}'
t "< sso cache"           block '{"tool_name":"Bash","tool_input":{"command":"< ~/.aws/sso/cache/0123abcd.json"}}'

echo "--- every reader reaches every reader rule ---"
# The reader alternation is repeated verbatim in the filter and in each reader
# rule, because the rules format has no way to share a fragment. One distinct
# copy means none has drifted; the loop then proves each rule honors it.
READER_GROUPS=$(grep -o '(?:cat|[^)]*)' "$RULES" | sort -u || true)
TOTAL=$((TOTAL + 1))
if [ -n "$READER_GROUPS" ] && [ "$(printf '%s\n' "$READER_GROUPS" | wc -l | tr -d ' ')" = 1 ]; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: one reader alternation across the filter and the rules"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: reader alternations differ: $(printf '%s ' $READER_GROUPS)"
fi
READERS=$(printf '%s\n' "$READER_GROUPS" | head -1 | sed 's/^(?:\(.*\))$/\1/' | tr '|' ' ')
for r in $READERS; do
  t "$r SSH key"          block "$(bash_input "$r ~/.ssh/id_rsa")"
  t "$r cloud credential" block "$(bash_input "$r ~/.aws/credentials")"
  t "$r secret-like name" ask   "$(bash_input "$r secrets.md")"
  t "$r .env"             ask   "$(bash_input "$r .env")"
  t "$r PEM"              ask   "$(bash_input "$r server.pem")"
  t "$r dotfile"          ask   "$(bash_input "$r ~/.bashrc")"
done

echo "--- block: echo secret env var ---"
t "echo \$SECRET_KEY"     block '{"tool_name":"Bash","tool_input":{"command":"echo $SECRET_KEY"}}'
t "echo \$API_KEY"        block '{"tool_name":"Bash","tool_input":{"command":"echo $API_KEY"}}'
t "printf \$PASSWORD"     block '{"tool_name":"Bash","tool_input":{"command":"printf \"%s\" $PASSWORD"}}'
t "echo \${TOKEN}"        block '{"tool_name":"Bash","tool_input":{"command":"echo ${TOKEN}"}}'

echo "--- ask: read files with secret-like names ---"
t "cat credentials.json"  ask   '{"tool_name":"Bash","tool_input":{"command":"cat /app/credentials.json"}}'
t "head .netrc_token"     ask   '{"tool_name":"Bash","tool_input":{"command":"head ~/.netrc_token"}}'
t "cat secrets.md"        ask   '{"tool_name":"Bash","tool_input":{"command":"cat secrets.md"}}'
t "< secrets.md"          ask   '{"tool_name":"Bash","tool_input":{"command":"sort < config/secrets.md"}}'

echo "--- ask: export secrets inline ---"
t "export SECRET_KEY="    ask   '{"tool_name":"Bash","tool_input":{"command":"export SECRET_KEY=abc123"}}'
t "export API_KEY="       ask   '{"tool_name":"Bash","tool_input":{"command":"export API_KEY=sk-12345"}}'
t "export DATABASE_URL="  ask   '{"tool_name":"Bash","tool_input":{"command":"export DATABASE_URL=postgres://user:pass@host/db"}}'

echo "--- ask: read .env files ---"
t "cat .env"              ask   '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}'
t "cat .env.local"        ask   '{"tool_name":"Bash","tool_input":{"command":"cat .env.local"}}'
t "< .env"                ask   '{"tool_name":"Bash","tool_input":{"command":"< .env"}}'

echo "--- ask: read PEM/key files ---"
t "cat server.pem"        ask   '{"tool_name":"Bash","tool_input":{"command":"cat server.pem"}}'
t "cat private.key"       ask   '{"tool_name":"Bash","tool_input":{"command":"cat private.key"}}'
t "openssl < server.pem"  ask   '{"tool_name":"Bash","tool_input":{"command":"openssl x509 -noout < server.pem"}}'

echo "--- ask: env / printenv ---"
t "env"                   ask   '{"tool_name":"Bash","tool_input":{"command":"env"}}'
t "env -i"                ask   '{"tool_name":"Bash","tool_input":{"command":"env -i bash"}}'
t "printenv"              ask   '{"tool_name":"Bash","tool_input":{"command":"printenv"}}'
# Compound commands: the env ask is escalated to a block (engine-level, see
# test-engine.sh). The bare env/printenv asks above keep rule-match coverage.
t "&& env (compound → block)"  block '{"tool_name":"Bash","tool_input":{"command":"cd /tmp && env"}}'
t '$(env) (compound → block)'  block '{"tool_name":"Bash","tool_input":{"command":"echo $(env | wc -l)"}}'

echo "--- allow: env-as-substring false positives ---"
t "comment w/ data-env"   allow '{"tool_name":"Bash","tool_input":{"command":"# Get the data-env around each occurrence\ngrep -B3 -A2 getty_dsa_es_7 docs/usage-report.md | head -25"}}'
t "cat data-env.txt"      allow '{"tool_name":"Bash","tool_input":{"command":"cat data-env.txt"}}'
t "grep printenv-extra"   allow '{"tool_name":"Bash","tool_input":{"command":"grep printenv-extra README.md"}}'

echo "--- ask: read dotfiles ---"
t "cat ~/.bashrc"         ask   '{"tool_name":"Bash","tool_input":{"command":"cat ~/.bashrc"}}'
t "cat ~/.gitconfig"      ask   '{"tool_name":"Bash","tool_input":{"command":"cat ~/.gitconfig"}}'
t "< ~/.gitconfig"        ask   '{"tool_name":"Bash","tool_input":{"command":"< ~/.gitconfig"}}'

echo "--- allow: cache directories under ~/.claude (issue #45) ---"
t "cat skill cache"       allow '{"tool_name":"Bash","tool_input":{"command":"cat ~/.claude/skills/example-skill/cache/status.json"}}'
t "tail skill cache log"  allow '{"tool_name":"Bash","tool_input":{"command":"tail -n 20 ~/.claude/skills/example-skill/cache/stage.log"}}'
t "< skill cache"         allow '{"tool_name":"Bash","tool_input":{"command":"< ~/.claude/skills/example-skill/cache/status.json"}}'
t "cat plugin cache"      allow '{"tool_name":"Bash","tool_input":{"command":"cat ~/.claude/plugins/cache/example-plugin/README.md"}}'

echo "--- ask: the cache exemption stays on the cache path ---"
asks_via "cat ~/.claude/.credentials.json"  "read dotfiles" "cat ~/.claude/.credentials.json"
asks_via "cat ~/.claude/settings.json"      "read dotfiles" "cat ~/.claude/settings.json"
asks_via "secret-named file in a cache"     "read files with secret-like names" "cat ~/.claude/skills/example-skill/cache/token.json"
asks_via ".. out of a skill cache"          "read dotfiles" "cat ~/.claude/skills/example-skill/cache/../../settings.json"
asks_via ".. out of the plugin cache"       "read dotfiles" "cat ~/.claude/plugins/cache/../../.credentials.json"
asks_via "variable after a cache path"      "read dotfiles" 'cat ~/.claude/plugins/cache/$TARGET'
asks_via "cache path beside a dotfile"      "read dotfiles" "cat ~/.claude/plugins/cache/example-plugin/README.md ~/.bashrc"
asks_via "a cache dir not under skills/<name>" "read dotfiles" "cat ~/.claude/cache/state.json"

echo "--- allow: a reader name inside a longer word ---"
t "bobcat ~/.ssh/id_rsa"  allow '{"tool_name":"Bash","tool_input":{"command":"bobcat ~/.ssh/id_rsa"}}'
t "my-cat ~/.ssh/id_rsa"  allow '{"tool_name":"Bash","tool_input":{"command":"my-cat ~/.ssh/id_rsa"}}'
t "git rev-parse"         allow '{"tool_name":"Bash","tool_input":{"command":"git rev-parse HEAD"}}'

echo "--- allow: < that is not an input redirect ---"
t "heredoc"               allow '{"tool_name":"Bash","tool_input":{"command":"python3 - <<'"'"'EOF'"'"'\nprint(1)\nEOF"}}'
t "process substitution"  allow '{"tool_name":"Bash","tool_input":{"command":"diff <(sort a.txt) ~/.bashrc"}}'
t "< inside an awk script" allow '{"tool_name":"Bash","tool_input":{"command":"awk '"'"'$1 < 5'"'"' ~/.bashrc"}}'
t "< to a plain file"     allow '{"tool_name":"Bash","tool_input":{"command":"wc -l < README.md"}}'

echo "--- allow: false-positive prevention (issue #3) ---"
# Natural-language commit messages with secret keywords must not block or ask
t "commit msg w/ token"   allow '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"more token handling\""}}'
t "commit msg w/ secret"  allow '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix tail of secret config\""}}'
t "heredoc commit"        allow '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"head over to docs for password setup\""}}'

echo "--- allow: safe operations ---"
t "cat normal file"       allow '{"tool_name":"Bash","tool_input":{"command":"cat README.md"}}'
t "echo normal string"    allow '{"tool_name":"Bash","tool_input":{"command":"echo hello world"}}'
t "ls -la"                allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
t "Write tool"            allow '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'

print_results
