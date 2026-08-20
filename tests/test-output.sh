#!/bin/bash
# Permission-prompt output formatting. Every reason reads
# `<rule>: <reason> — <ref>` — the same canonical form in the ask prompt, the
# deny error, and the decision log. Deny additionally carries the
# `[plugin:ClaudeWatch]` source tag the host omits on errors. Nothing on the
# display path emits a terminal escape sequence: the host replaces control
# characters in a hook's reason with U+FFFD, so one would reach the user as
# visible garbage.
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

echo "=== output formatting (canonical <rule>: <reason> — <ref>) ==="

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

# Print the emitted permissionDecisionReason for an input.
fmt_reason() {
  local input="$1"
  echo "$input" | env CLAUDEWATCH_LOG=off python3 "$HOOK" "$TMPDIR_OUT/watch-fmt.yml" 2>/dev/null \
    | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])'
}

# Assert the reason for $input does / does not contain $needle.
assert_reason() {
  local label="$1" input="$2" needle="$3" want="$4"
  TOTAL=$((TOTAL + 1))
  local r found=no
  r=$(fmt_reason "$input")
  printf '%s' "$r" | grep -qF -- "$needle" && found=yes
  if [ "$found" = "$want" ]; then
    PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $label"
  else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $label (needle found=$found, want=$want)"
  fi
}

ESC=$'\x1b'
NEEDS_REF='{"tool_name":"Bash","tool_input":{"command":"needs-ref"}}'
BARE='{"tool_name":"Bash","tool_input":{"command":"bare-only"}}'
MULTI='{"tool_name":"Bash","tool_input":{"command":"multimatch"}}'
BOOM='{"tool_name":"Bash","tool_input":{"command":"boom"}}'

echo "--- ask prompt: rule name, reason, and the ref inline ---"
assert_reason "prefix is the rule name"       "$NEEDS_REF" "with ref: has a doc link"    yes
assert_reason "ref appended after an em dash" "$NEEDS_REF" "— https://example.com/docs"  yes
assert_reason "redundant set name is dropped" "$NEEDS_REF" "watch-fmt"                   no

echo "--- a rule without a ref renders bare (no dangling separator) ---"
assert_reason "no-ref rule: plain reason text" "$BARE" "no ref: bare reason only" yes
assert_reason "no-ref rule: no separator"      "$BARE" "—"                        no

echo "--- multiple matched rules: each reason carries its own ref, newline-joined ---"
assert_reason "multi: first reason and ref"  "$MULTI" "first reason — https://example.com/one"   yes
assert_reason "multi: second reason and ref" "$MULTI" "second reason — https://example.com/two"  yes
# Two violations → two lines (one newline). A regression that joined them onto
# one line would fail here.
TOTAL=$((TOTAL + 1))
multi_lines=$(printf '%s\n' "$(fmt_reason "$MULTI")" | wc -l | tr -d ' ')
if [ "$multi_lines" = "2" ]; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: multi: reasons are newline-joined (2 lines)"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: multi: reasons are newline-joined (got $multi_lines lines)"
fi

echo "--- deny path uses the same canonical form ---"
run_test "$TMPDIR_OUT/watch-fmt.yml" "block rule denies" block "$BOOM"
assert_reason "deny reason shows the ref inline" "$BOOM" "danger: detonates everything — https://example.com/boom" yes

echo "--- no display path emits an escape sequence (the host renders them as U+FFFD) ---"
for label_input in "ask:$NEEDS_REF" "no-ref:$BARE" "multi:$MULTI" "deny:$BOOM"; do
  assert_reason "${label_input%%:*}: reason is escape-free" "${label_input#*:}" "$ESC" no
done

echo "--- deny path appends the [plugin:ClaudeWatch] source tag (ask gets it from the host) ---"
assert_reason "deny reason ends with the source tag"   "$BOOM"      "https://example.com/boom [plugin:ClaudeWatch]" yes
assert_reason "ask reason does not add the source tag" "$NEEDS_REF" "[plugin:ClaudeWatch]"                          no

echo "--- logged reasons match the displayed canonical form ---"
LOGF=$(mktemp -u /tmp/cw-fmtlog.XXXXXX.jsonl)
echo "$NEEDS_REF" \
  | env CLAUDEWATCH_LOG="$LOGF" python3 "$HOOK" "$TMPDIR_OUT/watch-fmt.yml" >/dev/null 2>&1 || true
TOTAL=$((TOTAL + 1))
if python3 -c 'import json,sys; rec=json.loads(open(sys.argv[1]).read().splitlines()[-1]); m=rec.get("matched",[]); sys.exit(0 if m and all("\x1b" not in x for x in m) and any("has a doc link — https://example.com/docs" in x for x in m) else 1)' "$LOGF"; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: logged matched reasons carry the ref inline, no escapes"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: logged matched reasons carry the ref inline, no escapes"
fi
rm -f "$LOGF"

# The deny display tag is a presentation detail; the log keeps the canonical form.
DENYLOG=$(mktemp -u /tmp/cw-denylog.XXXXXX.jsonl)
echo "$BOOM" \
  | env CLAUDEWATCH_LOG="$DENYLOG" python3 "$HOOK" "$TMPDIR_OUT/watch-fmt.yml" >/dev/null 2>&1 || true
TOTAL=$((TOTAL + 1))
if python3 -c 'import json,sys; rec=json.loads(open(sys.argv[1]).read().splitlines()[-1]); m=rec.get("matched",[]); sys.exit(0 if m and all("[plugin:ClaudeWatch]" not in x for x in m) else 1)' "$DENYLOG"; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: logged deny reason omits the source tag"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: logged deny reason omits the source tag"
fi
rm -f "$DENYLOG"

rm -rf "$TMPDIR_OUT"

print_results
