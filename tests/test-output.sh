#!/bin/bash
# Permission-prompt output formatting. The ask-prompt reason reads
# `<rule>: <reason>`, where the reason prose itself is a clickable OSC 8
# hyperlink to the rule's ref (on by default; CLAUDEWATCH_HYPERLINKS opts
# out). Deny messages always use the plain `— <url>` form, since the host
# renders them through its error path, which strips OSC 8 without linking
# it. The decision and the logged reasons stay plain text — only the prompt
# string changes.
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

echo "=== output formatting (ref → terminal hyperlink) ==="

TMPDIR_OUT=$(mktemp -d)
cat > "$TMPDIR_OUT/watch-fmt.yml" <<'YAMLEOF'
name: watch-fmt
rules:
  block:
    - name: danger
      pattern: 'boom'
      reason: detonates everything
      ref: https://example.com/boom
  ask:
    - name: with ref
      pattern: 'needs-ref'
      reason: has a doc link
      ref: https://example.com/docs
    - name: no ref
      pattern: 'bare-only'
      reason: bare reason only
    - name: first multi
      pattern: 'multimatch'
      reason: first reason
      ref: https://example.com/one
    - name: second multi
      pattern: 'multimatch'
      reason: second reason
      ref: https://example.com/two
YAMLEOF

# Print the emitted permissionDecisionReason for an input under given env.
fmt_reason() {
  local env_kv="$1" input="$2"
  echo "$input" | env $env_kv CLAUDEWATCH_LOG=off node "$HOOK" "$TMPDIR_OUT/watch-fmt.yml" 2>/dev/null \
    | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])'
}

# Assert the reason for $input (under env $2) does / does not contain $needle.
assert_reason() {
  local label="$1" env_kv="$2" input="$3" needle="$4" want="$5"
  TOTAL=$((TOTAL + 1))
  local r found=no
  r=$(fmt_reason "$env_kv" "$input")
  printf '%s' "$r" | grep -qF -- "$needle" && found=yes
  if [ "$found" = "$want" ]; then
    PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $label"
  else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $label (needle found=$found, want=$want)"
  fi
}

OSC8=$'\x1b]8;;'
ST=$'\x1b\\'
NL=$'\n'
NEEDS_REF='{"tool_name":"Bash","tool_input":{"command":"needs-ref"}}'
BARE='{"tool_name":"Bash","tool_input":{"command":"bare-only"}}'
MULTI='{"tool_name":"Bash","tool_input":{"command":"multimatch"}}'
BOOM='{"tool_name":"Bash","tool_input":{"command":"boom"}}'

echo "--- default: the reason prose becomes an OSC 8 hyperlink ---"
assert_reason "default emits OSC 8 sequence"     "-u CLAUDEWATCH_HYPERLINKS" "$NEEDS_REF" "$OSC8"                              yes
assert_reason "default targets ref URL as href"  "-u CLAUDEWATCH_HYPERLINKS" "$NEEDS_REF" "https://example.com/docs"          yes
assert_reason "prefix is the rule name"          "-u CLAUDEWATCH_HYPERLINKS" "$NEEDS_REF" "with ref: "                       yes
assert_reason "redundant set name is dropped"    "-u CLAUDEWATCH_HYPERLINKS" "$NEEDS_REF" "watch-fmt"                        no
assert_reason "default links the reason prose"   "-u CLAUDEWATCH_HYPERLINKS" "$NEEDS_REF" "${OSC8}https://example.com/docs${ST}has a doc link" yes

echo "--- CLAUDEWATCH_HYPERLINKS opt-out covers the full off-set ---"
for off in off 0 false none ""; do
  assert_reason "off-value '${off}' disables hyperlinks" "CLAUDEWATCH_HYPERLINKS=$off" "$NEEDS_REF" "$OSC8" no
done
assert_reason "off shows the bare url"           "CLAUDEWATCH_HYPERLINKS=off" "$NEEDS_REF" "— https://example.com/docs"      yes

echo "--- a rule without a ref never hyperlinks (no dangling separator) ---"
assert_reason "no-ref rule: no escape sequence"  "-u CLAUDEWATCH_HYPERLINKS" "$BARE" "$OSC8"                       no
assert_reason "no-ref rule: plain reason text"   "-u CLAUDEWATCH_HYPERLINKS" "$BARE" "no ref: bare reason only" yes

echo "--- multiple matched rules: each reason links independently, newline-joined ---"
assert_reason "multi: first rule linked"   "-u CLAUDEWATCH_HYPERLINKS" "$MULTI" "${OSC8}https://example.com/one${ST}first reason"  yes
assert_reason "multi: second rule linked"  "-u CLAUDEWATCH_HYPERLINKS" "$MULTI" "${OSC8}https://example.com/two${ST}second reason" yes
# Two violations → two lines (one newline). A regression that wrapped the joined
# string in a single hyperlink, or dropped the newline, would fail here.
TOTAL=$((TOTAL + 1))
multi_lines=$(printf '%s\n' "$(fmt_reason "-u CLAUDEWATCH_HYPERLINKS" "$MULTI")" | wc -l | tr -d ' ')
if [ "$multi_lines" = "2" ]; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: multi: reasons are newline-joined (2 lines)"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: multi: reasons are newline-joined (got $multi_lines lines)"
fi

echo "--- deny path uses the plain — url form (host strips OSC 8 on errors) ---"
run_test "$TMPDIR_OUT/watch-fmt.yml" "block rule denies" block "$BOOM"
assert_reason "deny reason has no escape sequence"  "-u CLAUDEWATCH_HYPERLINKS" "$BOOM" "$OSC8"                                  no
assert_reason "deny reason shows the bare url"      "-u CLAUDEWATCH_HYPERLINKS" "$BOOM" "danger: detonates everything — https://example.com/boom" yes

echo "--- deny path appends the [plugin:ClaudeWatch] source tag (ask gets it from the host) ---"
assert_reason "deny reason ends with the source tag" "-u CLAUDEWATCH_HYPERLINKS" "$BOOM" "https://example.com/boom [plugin:ClaudeWatch]" yes
assert_reason "ask reason does not add the source tag" "-u CLAUDEWATCH_HYPERLINKS" "$NEEDS_REF" "[plugin:ClaudeWatch]" no

echo "--- logged reasons stay plain text even with hyperlinks on ---"
LOGF=$(mktemp /tmp/cw-fmtlog.XXXXXX.jsonl)
echo "$NEEDS_REF" \
  | env -u CLAUDEWATCH_HYPERLINKS CLAUDEWATCH_LOG="$LOGF" node "$HOOK" "$TMPDIR_OUT/watch-fmt.yml" >/dev/null 2>&1 || true
TOTAL=$((TOTAL + 1))
if python3 -c 'import json,sys; rec=json.loads(open(sys.argv[1]).read().splitlines()[-1]); m=rec.get("matched",[]); sys.exit(0 if m and all("\x1b]8;;" not in x for x in m) and any("https://example.com/docs" in x for x in m) else 1)' "$LOGF"; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: logged matched reasons are plain (url inline, no escapes)"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: logged matched reasons are plain"
fi
rm -f "$LOGF"

# The deny display tag is a presentation detail; the log keeps the canonical form.
DENYLOG=$(mktemp /tmp/cw-denylog.XXXXXX.jsonl)
echo "$BOOM" \
  | env -u CLAUDEWATCH_HYPERLINKS CLAUDEWATCH_LOG="$DENYLOG" node "$HOOK" "$TMPDIR_OUT/watch-fmt.yml" >/dev/null 2>&1 || true
TOTAL=$((TOTAL + 1))
if python3 -c 'import json,sys; rec=json.loads(open(sys.argv[1]).read().splitlines()[-1]); m=rec.get("matched",[]); sys.exit(0 if m and all("[plugin:ClaudeWatch]" not in x for x in m) else 1)' "$DENYLOG"; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: logged deny reason omits the source tag"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: logged deny reason omits the source tag"
fi
rm -f "$DENYLOG"

rm -rf "$TMPDIR_OUT"

print_results
