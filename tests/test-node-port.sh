#!/bin/bash
# Behaviors specific to the Node engine port (scripts/watchdog.mjs) that close
# gaps found in review. Each test pins a behavior that must match the Python
# engine (watchdog.py) — or, for the two documented v1.0.0 limitations, pins the
# accepted JS RegExp / UTF-8 behavior so it can't silently change.
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

echo "=== Node port: faithfulness and documented limitations ==="

TMPDIR_NP=$(mktemp -d)

# ---------------------------------------------------------------------------
# 1. Large decision output is not truncated.
#
# process.exit(0) immediately after an async stdout.write can drop a decision
# JSON larger than the OS pipe buffer (~64KB). Build a single block reason far
# larger than that and assert the FULL JSON line arrives intact and parses.
# ---------------------------------------------------------------------------
echo "--- large coalesced decision arrives intact (no stdout truncation) ---"
# A reason ~200KB long, well past any pipe buffer.
HUGE_REASON=$(python3 -c 'print("X" * 200000, end="")')
cat > "$TMPDIR_NP/huge.yml" <<YAMLEOF
name: huge
rules:
  block:
    - name: huge rule
      pattern: 'boom'
      reason: '$HUGE_REASON'
      ref: n/a
YAMLEOF
TOTAL=$((TOTAL + 1))
HUGE_OUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"boom"}}' \
  | node "$HOOK" "$TMPDIR_NP/huge.yml" 2>/dev/null || true)
# The output must be one complete, parseable JSON line whose reason is the full
# 200KB payload — a truncated write would fail to parse or be short.
if python3 -c '
import json, sys
out = sys.stdin.read()
rec = json.loads(out)
reason = rec["hookSpecificOutput"]["permissionDecisionReason"]
sys.exit(0 if rec["hookSpecificOutput"]["permissionDecision"] == "deny" and reason.count("X") == 200000 else 1)
' <<< "$HUGE_OUT" 2>/dev/null; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: large decision JSON not truncated"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: large decision JSON not truncated (len=${#HUGE_OUT})"
fi

# ---------------------------------------------------------------------------
# 2. Empty old_string Edit reconstruction matches Python str.replace.
#
#   ''.replace('', 'X')       -> 'X'      (empty file, replace_all)
#   ''.replace('', 'X', 1)    -> 'X'      (empty file, first-only)
#   'ab'.replace('', 'X')     -> 'XaXbX'  (non-empty file, replace_all)
#   'ab'.replace('', 'X', 1)  -> 'Xab'    (non-empty file, first-only)
#
# A pattern that matches the reconstructed content fires; one that doesn't,
# doesn't — so the decision is the proof the reconstruction is exact.
# ---------------------------------------------------------------------------
cat > "$TMPDIR_NP/recon.yml" <<'YAMLEOF'
name: recon
extensions: ['.foo']
rules:
  block:
    # Matches only when the empty-needle insertion produced the EXACT shape.
    - name: empty-file shape
      pattern: '^X$'
      target: file-content
      reason: empty file became exactly X
      ref: n/a
    - name: interleaved-all shape
      pattern: '^XaXbX$'
      target: file-content
      reason: ab became XaXbX (replace_all)
      ref: n/a
    - name: prepend-first shape
      pattern: '^Xab$'
      target: file-content
      reason: ab became Xab (first-only)
      ref: n/a
YAMLEOF

echo "--- empty old_string on empty file: replace_all -> 'X' ---"
EMPTY_FILE=$(mktemp "$TMPDIR_NP/empty.XXXXXX.foo"); : > "$EMPTY_FILE"
run_test "$TMPDIR_NP/recon.yml" "empty file replace_all = single X" block \
  "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"","new_string":"X","replace_all":true}}' "$EMPTY_FILE")"

echo "--- empty old_string on empty file: first-only -> 'X' ---"
EMPTY_FILE2=$(mktemp "$TMPDIR_NP/empty2.XXXXXX.foo"); : > "$EMPTY_FILE2"
run_test "$TMPDIR_NP/recon.yml" "empty file first-only = single X" block \
  "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"","new_string":"X"}}' "$EMPTY_FILE2")"

echo "--- empty old_string on 'ab': replace_all -> 'XaXbX' ---"
AB_FILE=$(mktemp "$TMPDIR_NP/ab.XXXXXX.foo"); printf 'ab' > "$AB_FILE"
run_test "$TMPDIR_NP/recon.yml" "ab replace_all = XaXbX" block \
  "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"","new_string":"X","replace_all":true}}' "$AB_FILE")"

echo "--- empty old_string on 'ab': first-only -> 'Xab' ---"
AB_FILE2=$(mktemp "$TMPDIR_NP/ab2.XXXXXX.foo"); printf 'ab' > "$AB_FILE2"
run_test "$TMPDIR_NP/recon.yml" "ab first-only = Xab" block \
  "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"","new_string":"X"}}' "$AB_FILE2")"

# ---------------------------------------------------------------------------
# 3. command_shape uses a Python-faithful basename.
#
# Python os.path.basename('foo/') is '' (Node path.basename would give 'foo').
# A program token ending in '/' must shape to '' so the logged shape matches the
# contract analyze.py re-derives. Verify the logged command_shape directly.
# ---------------------------------------------------------------------------
echo "--- command_shape basename: trailing-slash program shapes to '' ---"
SHAPELOG=$(mktemp /tmp/cw-shape.XXXXXX.jsonl)
echo '{"tool_name":"Bash","tool_input":{"command":"bar/ arg"}}' \
  | CLAUDEWATCH_LOG="$SHAPELOG" node "$HOOK" "$RULES_DIR" >/dev/null 2>&1 || true
TOTAL=$((TOTAL + 1))
if python3 -c 'import json,sys; rec=json.loads(open(sys.argv[1]).read().splitlines()[-1]); sys.exit(0 if rec.get("command_shape") == "" else 1)' "$SHAPELOG" 2>/dev/null; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: 'bar/ arg' shapes to '' (Python basename)"
else
  GOT=$(python3 -c 'import json,sys; print(repr(json.loads(open(sys.argv[1]).read().splitlines()[-1]).get("command_shape")))' "$SHAPELOG" 2>/dev/null || true)
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: 'bar/ arg' shapes to '' (got $GOT)"
fi
rm -f "$SHAPELOG"

# ---------------------------------------------------------------------------
# 5. ts format matches Python datetime.isoformat: a +00:00 suffix, and a
#    fractional part that is either absent or exactly 6 digits.
# ---------------------------------------------------------------------------
echo "--- log ts matches Python isoformat shape (+00:00, 0 or 6 frac digits) ---"
TSLOG=$(mktemp /tmp/cw-ts.XXXXXX.jsonl)
echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
  | CLAUDEWATCH_LOG="$TSLOG" node "$HOOK" "$RULES_DIR" >/dev/null 2>&1 || true
TOTAL=$((TOTAL + 1))
if python3 -c '
import json, re, sys
ts = json.loads(open(sys.argv[1]).read().splitlines()[-1])["ts"]
# YYYY-MM-DDTHH:MM:SS then optional .ffffff (exactly 6) then +00:00
ok = re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{6})?\+00:00", ts) is not None
sys.exit(0 if ok else 1)
' "$TSLOG" 2>/dev/null; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: ts has +00:00 suffix and 0-or-6 fractional digits"
else
  GOT=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["ts"])' "$TSLOG" 2>/dev/null || true)
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: ts isoformat shape (got $GOT)"
fi
rm -f "$TSLOG"

# ---------------------------------------------------------------------------
# 6. Documented limitation: JS RegExp semantics (SPEC.md, EN section).
#
#    (a) \w is ASCII, not Unicode. A non-ASCII word char adjacent to a guarded
#        token does not match. `export MÝSECRET=1` does NOT fire watch-secrets
#        (Python's Unicode \w would have matched). Pinning asserts the engine
#        uses the documented JS behavior.
#    (b) trailing `$` matches only at true end-of-string, not before a final \n.
# ---------------------------------------------------------------------------
echo "--- documented: ASCII \\w — non-ASCII word char adjacent to a token does not match ---"
# Build the input via printf so the literal export string isn't on a Bash line.
UNICODE_IN=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(printf 'export M\303\235SECRET=1')")
run_test "$RULES_DIR/watch-secrets.yml" "non-ASCII word char does not match (JS ASCII \\w)" allow "$UNICODE_IN"
# Control: the all-ASCII form DOES match (ask), confirming the rule itself is live.
ASCII_IN=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(printf 'export MYSECRET=1')")
run_test "$RULES_DIR/watch-secrets.yml" "all-ASCII secret var still matches (control)" ask "$ASCII_IN"

echo "--- documented: trailing \$ matches only at true end-of-string ---"
cat > "$TMPDIR_NP/anchor.yml" <<'YAMLEOF'
name: anchor
rules:
  block:
    - name: end anchor
      pattern: 'foo$'
      reason: matched foo at end
      ref: n/a
YAMLEOF
# A bash command can't carry a trailing newline through the harness, so pin the
# documented JS behavior on file content (target rules need an extension; reuse
# bash target with a newline-terminated content via Write).
cat > "$TMPDIR_NP/anchor-fc.yml" <<'YAMLEOF'
name: anchor-fc
extensions: ['.foo']
rules:
  block:
    - name: end anchor
      pattern: 'foo$'
      target: file-content
      reason: matched foo at end-of-string
      ref: n/a
YAMLEOF
# "foo" with no trailing newline: JS $ matches at true end -> block.
run_test "$TMPDIR_NP/anchor-fc.yml" "\$ matches at true end-of-string" block \
  '{"tool_name":"Write","tool_input":{"file_path":"x.foo","content":"foo"}}'
# "foo\n": Python $ matches before the final \n, JS $ does NOT -> allow (the
# documented JS-only behavior). \n is escaped in the JSON string.
run_test "$TMPDIR_NP/anchor-fc.yml" "\$ does not match before a final newline (JS semantics)" allow \
  '{"tool_name":"Write","tool_input":{"file_path":"x.foo","content":"foo\n"}}'

# ---------------------------------------------------------------------------
# 7. Documented improvement: invalid UTF-8 in an Edit target file.
#
# Node reads with U+FFFD substitution and still produces a decision and exit 0.
# (Python raised UnicodeDecodeError and crashed non-zero, violating exit-0.)
# Write raw invalid bytes (0xff 0xfe) into the file, then Edit it; the engine
# must still emit a decision (here, fire on the new_string) and exit 0.
# ---------------------------------------------------------------------------
echo "--- documented improvement: invalid-UTF-8 Edit target still decides and exits 0 ---"
BADUTF=$(mktemp "$TMPDIR_NP/badutf.XXXXXX.foo")
printf '\377\376 some text destroy-edit ' > "$BADUTF"
cat > "$TMPDIR_NP/utf.yml" <<'YAMLEOF'
name: utf
extensions: ['.foo']
rules:
  block:
    - name: edit content
      pattern: 'destroy-edit'
      target: file-content
      reason: edited content contains the guarded token
      ref: n/a
YAMLEOF
TOTAL=$((TOTAL + 1))
UTF_INPUT=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"some text","new_string":"some text destroy-edit"}}' "$BADUTF")
UTF_OUT=$(echo "$UTF_INPUT" | node "$HOOK" "$TMPDIR_NP/utf.yml" 2>/dev/null)
UTF_RC=$?
if [ "$UTF_RC" -eq 0 ] && echo "$UTF_OUT" | grep -q '"permissionDecision":"deny"'; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: invalid-UTF-8 Edit target decided (deny) and exited 0"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: invalid-UTF-8 Edit (rc=$UTF_RC, out=${UTF_OUT:-empty})"
fi

rm -rf "$TMPDIR_NP"

print_results
