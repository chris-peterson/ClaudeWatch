#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

echo "=== error handling (fail closed) ==="

TMPDIR_TESTS=$(mktemp -d)

echo "--- block: invalid regex in rule ---"
cat > "$TMPDIR_TESTS/bad-regex.yml" <<'YAMLEOF'
name: bad-regex
rules:
  block:
    - name: bad pattern
      pattern: '[invalid('
      reason: this regex is broken
      ref: n/a
YAMLEOF
run_test "$TMPDIR_TESTS/bad-regex.yml" "invalid regex blocks" block \
  '{"tool_name":"Bash","tool_input":{"command":"anything"}}'

echo "--- block: empty pattern in rule ---"
cat > "$TMPDIR_TESTS/empty-pattern.yml" <<'YAMLEOF'
name: empty-pattern
rules:
  block:
    - name: missing pattern
      patern: 'typo'
      reason: field name is wrong
      ref: n/a
YAMLEOF
run_test "$TMPDIR_TESTS/empty-pattern.yml" "empty pattern blocks" block \
  '{"tool_name":"Bash","tool_input":{"command":"anything"}}'

echo "--- block: invalid filter regex ---"
cat > "$TMPDIR_TESTS/bad-filter.yml" <<'YAMLEOF'
name: bad-filter
filter: '[broken('
rules:
  ask:
    - name: test
      pattern: 'test'
      reason: test
      ref: n/a
YAMLEOF
run_test "$TMPDIR_TESTS/bad-filter.yml" "invalid filter blocks" block \
  '{"tool_name":"Bash","tool_input":{"command":"test something"}}'

echo "--- block: missing rules file ---"
run_test "$TMPDIR_TESTS/nonexistent.yml" "missing file blocks" block \
  '{"tool_name":"Bash","tool_input":{"command":"anything"}}'

echo "--- except bypasses ask but not block ---"
cat > "$TMPDIR_TESTS/except-test.yml" <<'YAMLEOF'
name: except-test
rules:
  block:
    - name: dangerous
      pattern: 'rm.*--no-preserve-root'
      reason: destroys filesystem
      ref: n/a
  ask:
    - name: rm -rf
      pattern: 'rm\s+-rf'
      except: '/tmp/'
      reason: recursive delete
      ref: n/a
YAMLEOF
run_test "$TMPDIR_TESTS/except-test.yml" "except bypasses ask" allow \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/build"}}'
run_test "$TMPDIR_TESTS/except-test.yml" "except does not bypass block" block \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf --no-preserve-root /tmp/"}}'
run_test "$TMPDIR_TESTS/except-test.yml" "ask fires without except match" ask \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf ./src"}}'

echo "--- except on block emits warning ---"
cat > "$TMPDIR_TESTS/except-block-warn.yml" <<'YAMLEOF'
name: except-block-warn
rules:
  block:
    - name: dangerous
      pattern: 'rm -rf'
      except: '/tmp/'
      reason: destroys stuff
      ref: n/a
YAMLEOF
run_test "$TMPDIR_TESTS/except-block-warn.yml" "except on block still blocks" block \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/build"}}'

echo "--- unrecognized YAML field emits warning to stderr ---"
cat > "$TMPDIR_TESTS/typo-field.yml" <<'YAMLEOF'
name: typo-field
rules:
  ask:
    - name: rule with typo
      pattern: 'whatever'
      refrence: 'this typo should warn'
      reason: typo'd ref field
      ref: n/a
YAMLEOF
TYPO_STDERR=$(echo '{"tool_name":"Bash","tool_input":{"command":"whatever"}}' \
  | python3 "$HOOK" "$TMPDIR_TESTS/typo-field.yml" 2>&1 >/dev/null || true)
TOTAL=$((TOTAL + 1))
if echo "$TYPO_STDERR" | grep -q "unrecognized line"; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: unrecognized YAML field warns"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: unrecognized YAML field warns (stderr: ${TYPO_STDERR:-empty})"
fi

rm -rf "$TMPDIR_TESTS"

echo ""
echo "=== cross-ruleset isolation ==="
run_test "$SCRIPT_DIR/../watches/watch-git.yml" "npm install (git rules)" allow \
  '{"tool_name":"Bash","tool_input":{"command":"npm install lodash"}}'
run_test "$SCRIPT_DIR/../watches/watch-installs.yml" "git push (install rules)" allow \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'

echo ""
echo "=== target dispatch (bash vs file-content) ==="

TMPDIR_TARGETS=$(mktemp -d)

cat > "$TMPDIR_TARGETS/watch-target.yml" <<'YAMLEOF'
name: watch-target
filter: '\bfoo\b'
extensions: ['.foo']

rules:
  block:
    - name: bash-only block
      pattern: 'destroy-bash'
      target: bash
      reason: bash block rule fired
      ref: n/a
    - name: file-content-only block
      pattern: 'destroy-file'
      target: file-content
      reason: file-content block rule fired
      ref: n/a
  ask:
    - name: default-target ask
      pattern: 'ask-default'
      reason: default target should be bash
      ref: n/a
YAMLEOF

echo "--- bash input runs only target=bash rules ---"
run_test "$TMPDIR_TARGETS/watch-target.yml" "bash rule fires on bash input" block \
  '{"tool_name":"Bash","tool_input":{"command":"foo destroy-bash"}}'
run_test "$TMPDIR_TARGETS/watch-target.yml" "file-content rule skipped on bash input" allow \
  '{"tool_name":"Bash","tool_input":{"command":"foo destroy-file"}}'

echo "--- omitted target defaults to bash ---"
run_test "$TMPDIR_TARGETS/watch-target.yml" "default target is bash" ask \
  '{"tool_name":"Bash","tool_input":{"command":"foo ask-default"}}'

echo "--- Write input runs only target=file-content rules ---"
run_test "$TMPDIR_TARGETS/watch-target.yml" "file-content rule fires on Write" block \
  '{"tool_name":"Write","tool_input":{"file_path":"x.foo","content":"destroy-file here"}}'
run_test "$TMPDIR_TARGETS/watch-target.yml" "bash rule skipped on Write" allow \
  '{"tool_name":"Write","tool_input":{"file_path":"x.foo","content":"destroy-bash here"}}'

echo "--- extensions gate file-content rules ---"
run_test "$TMPDIR_TARGETS/watch-target.yml" "non-matching extension skipped" allow \
  '{"tool_name":"Write","tool_input":{"file_path":"x.bar","content":"destroy-file"}}'
run_test "$TMPDIR_TARGETS/watch-target.yml" "case-insensitive extension match" block \
  '{"tool_name":"Write","tool_input":{"file_path":"x.FOO","content":"destroy-file"}}'

echo "--- rule set without extensions ignores file-content rules ---"
cat > "$TMPDIR_TARGETS/no-extensions.yml" <<'YAMLEOF'
name: no-extensions
rules:
  block:
    - name: file-content-without-extensions
      pattern: 'destroy-file'
      target: file-content
      reason: should not fire — rule set has no extensions
      ref: n/a
YAMLEOF
run_test "$TMPDIR_TARGETS/no-extensions.yml" "missing extensions = no file-content eval" allow \
  '{"tool_name":"Write","tool_input":{"file_path":"x.anything","content":"destroy-file"}}'

echo "--- filter gates bash-target only ---"
run_test "$TMPDIR_TARGETS/watch-target.yml" "bash filter skips non-matching" allow \
  '{"tool_name":"Bash","tool_input":{"command":"destroy-bash without keyword"}}'
run_test "$TMPDIR_TARGETS/watch-target.yml" "filter does not gate file-content" block \
  '{"tool_name":"Write","tool_input":{"file_path":"x.foo","content":"destroy-file without filter keyword"}}'

echo "--- invalid target blocks ---"
cat > "$TMPDIR_TARGETS/bad-target.yml" <<'YAMLEOF'
name: bad-target
filter: '.'
rules:
  block:
    - name: bogus target
      pattern: 'anything'
      target: bogus
      reason: invalid target value
      ref: n/a
YAMLEOF
run_test "$TMPDIR_TARGETS/bad-target.yml" "invalid target value blocks" block \
  '{"tool_name":"Bash","tool_input":{"command":"anything"}}'

echo "--- Edit reconstructs full post-edit content ---"
TMPFILE_EDIT=$(mktemp "$TMPDIR_TARGETS/script.XXXXXX.foo")
cat > "$TMPFILE_EDIT" <<'EOF'
benign code here
no-op placeholder
more benign code
EOF
run_test "$TMPDIR_TARGETS/watch-target.yml" "edit introduces match in full content" block \
  "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"no-op placeholder","new_string":"destroy-file the world"}}' "$TMPFILE_EDIT")"
run_test "$TMPDIR_TARGETS/watch-target.yml" "edit leaves benign content benign" allow \
  "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"no-op placeholder","new_string":"still benign"}}' "$TMPFILE_EDIT")"

echo "--- Edit on missing file falls back to new_string ---"
run_test "$TMPDIR_TARGETS/watch-target.yml" "missing-file edit matches new_string" block \
  '{"tool_name":"Edit","tool_input":{"file_path":"/no/such/path.foo","old_string":"","new_string":"destroy-file"}}'

echo "--- Edit replace_all replaces every occurrence ---"
TMPFILE_REPLACE=$(mktemp "$TMPDIR_TARGETS/multi.XXXXXX.foo")
printf 'X token\nX token\nY here\n' > "$TMPFILE_REPLACE"
run_test "$TMPDIR_TARGETS/watch-target.yml" "replace_all reconstructs every match" block \
  "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"token","new_string":"destroy-file","replace_all":true}}' "$TMPFILE_REPLACE")"

echo "--- unsupported tool names exit silently ---"
run_test "$TMPDIR_TARGETS/watch-target.yml" "Read tool produces no output" allow \
  '{"tool_name":"Read","tool_input":{"file_path":"anything"}}'
run_test "$TMPDIR_TARGETS/watch-target.yml" "Grep tool produces no output" allow \
  '{"tool_name":"Grep","tool_input":{"pattern":"destroy-file"}}'

rm -rf "$TMPDIR_TARGETS"

echo ""
echo "=== directory mode ==="
run_test "$RULES_DIR" "git block (dir)"     block '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
run_test "$RULES_DIR" "git ask (dir)"       ask   '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}'
run_test "$RULES_DIR" "install block (dir)" block '{"tool_name":"Bash","tool_input":{"command":"curl -fsSL https://example.com | sh"}}'
run_test "$RULES_DIR" "install ask (dir)"   ask   '{"tool_name":"Bash","tool_input":{"command":"npm install lodash"}}'
run_test "$RULES_DIR" "file block (dir)"    block '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
run_test "$RULES_DIR" "file ask (dir)"      ask   '{"tool_name":"Bash","tool_input":{"command":"rm -rf ./build"}}'
run_test "$RULES_DIR" "secret block (dir)"  block '{"tool_name":"Bash","tool_input":{"command":"cat ~/.ssh/id_rsa"}}'
run_test "$RULES_DIR" "secret ask (dir)"    ask   '{"tool_name":"Bash","tool_input":{"command":"cat ~/.bashrc"}}'
run_test "$RULES_DIR" "file except (dir)"    allow '{"tool_name":"Bash","tool_input":{"command":"rm -rf ~/.cache/pip"}}'
run_test "$RULES_DIR" "safe cmd (dir)"      allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'

echo ""
echo "=== compound-command ask escalation ==="
# A piped/chained bash command whose segments each match a host allow rule can be
# auto-approved by Claude Code, pre-empting the hook's ask (deny is still honored).
# The engine escalates an ask to a deny when the bash command is compound, since
# deny survives the pipe. Operators inside quotes are not shell operators and must
# not escalate, so a guarded command bare or with a quoted operator still prompts.
run_test "$RULES_DIR" "bare ask prompts"                    ask   '{"tool_name":"Bash","tool_input":{"command":"git stash list"}}'
run_test "$RULES_DIR" "piped ask escalates to block"        block '{"tool_name":"Bash","tool_input":{"command":"git stash list | tail -4"}}'
run_test "$RULES_DIR" "chained ask (&&) escalates to block" block '{"tool_name":"Bash","tool_input":{"command":"git add . && git commit -m \"wip\""}}'
run_test "$RULES_DIR" "sequenced ask (;) escalates to block" block '{"tool_name":"Bash","tool_input":{"command":"git commit -m wip; echo done"}}'
run_test "$RULES_DIR" "quoted operators in commit msg stay ask" ask '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"wip | cleanup; done\""}}'
run_test "$RULES_DIR" "cmd-subst inside quotes stays ask"   ask   '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(printf done)\""}}'
run_test "$RULES_DIR" "block through pipe unaffected"       block '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main | tail -4"}}'
run_test "$RULES_DIR" "allow through pipe stays silent"     allow '{"tool_name":"Bash","tool_input":{"command":"ls -la | tail -4"}}'

print_results
