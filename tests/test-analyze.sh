#!/bin/bash
# Decision-log analyzer (scripts/analyze-decisions.py). Builds a synthetic log
# plus a stub allow list and asserts the three proposal buckets.
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

ANALYZE="$SCRIPT_DIR/../scripts/analyze-decisions.py"

echo "=== decision log analysis ==="

TMP=$(mktemp -d /tmp/cw-analyze.XXXXXX)
LOG="$TMP/decisions.jsonl"
SETTINGS="$TMP/settings.json"
OUT="$TMP/out.json"

# Allow list already covers jq, so jq must NOT be re-proposed.
cat > "$SETTINGS" <<'EOF'
{"permissions":{"allow":["Bash(jq:*)"]}}
EOF

# Synthetic log:
#   gh pr view  x4  allow, not allow-listed   -> allow_candidate
#   jq          x3  allow, allow-listed       -> suppressed
#   git commit  x3  ask                       -> except_candidate
#   force push  x2  deny                      -> deny_summary
cat > "$LOG" <<'EOF'
{"ts":"2026-05-31T10:00:00+00:00","session":"s1","decision":"allow","tool":"Bash","mode":"auto","command":"gh pr view 1","cwd":"/a"}
{"ts":"2026-05-31T10:01:00+00:00","decision":"allow","tool":"Bash","mode":"auto","command":"gh pr view 2","cwd":"/a"}
{"ts":"2026-05-31T10:02:00+00:00","decision":"allow","tool":"Bash","mode":"auto","command":"gh pr view 3","cwd":"/b"}
{"ts":"2026-05-31T10:03:00+00:00","decision":"allow","tool":"Bash","mode":"default","command":"gh pr view 4","cwd":"/b"}
{"ts":"2026-05-31T10:04:00+00:00","decision":"allow","tool":"Bash","command":"jq .x a.json","cwd":"/a"}
{"ts":"2026-05-31T10:05:00+00:00","decision":"allow","tool":"Bash","command":"jq .y b.json","cwd":"/a"}
{"ts":"2026-05-31T10:06:00+00:00","decision":"allow","tool":"Bash","command":"jq .z c.json","cwd":"/a"}
{"ts":"2026-05-31T10:07:00+00:00","session":"s2","decision":"ask","tool":"Bash","command":"git commit -m a","matched":["watch-git — git commit"],"cwd":"/a"}
{"ts":"2026-05-31T10:08:00+00:00","decision":"ask","tool":"Bash","command":"git commit -m b","matched":["watch-git — git commit"],"cwd":"/a"}
{"ts":"2026-05-31T10:09:00+00:00","decision":"ask","tool":"Bash","command":"git commit -m c","matched":["watch-git — git commit"],"cwd":"/a"}
{"ts":"2026-05-31T10:10:00+00:00","decision":"deny","tool":"Bash","command":"git push --force origin main","matched":["watch-git — force push"],"cwd":"/a"}
{"ts":"2026-05-31T10:11:00+00:00","decision":"deny","tool":"Bash","command":"git push --force origin dev","matched":["watch-git — force push"],"cwd":"/a"}
EOF

assert_json() {
  local label="$1" expr="$2"
  TOTAL=$((TOTAL + 1))
  if python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if ($expr) else 1)
" "$OUT" 2>/dev/null; then
    PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $label"
  else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $label"
  fi
}

python3 "$ANALYZE" --log "$LOG" --settings "$SETTINGS" --min-count 2 > "$OUT" 2>/dev/null

assert_json "gh pr view is an allow candidate (count 4)" \
  "any(c['shape']=='gh pr view' and c['count']==4 for c in d['allow_candidates'])"
assert_json "gh pr view suggests Bash(gh pr view:*)" \
  "any(c['shape']=='gh pr view' and c['suggested_allow']=='Bash(gh pr view:*)' for c in d['allow_candidates'])"
assert_json "gh pr view shows 3 auto-executed of 4" \
  "any(c['shape']=='gh pr view' and c['auto_executed']==3 for c in d['allow_candidates'])"
assert_json "by_mode tallies auto and default" \
  "d['by_mode'].get('auto')==3 and d['by_mode'].get('default')==1"
assert_json "meta reports distinct sessions (s1, s2)" \
  "d['meta']['distinct_sessions']==2"
assert_json "meta reports the oldest and newest record ts" \
  "d['meta']['oldest_ts']=='2026-05-31T10:00:00+00:00' and d['meta']['newest_ts']=='2026-05-31T10:11:00+00:00'"
assert_json "meta reports the span in days" \
  "d['meta']['span_days']==0.01"
assert_json "allow-listed jq is suppressed" \
  "all(c['shape']!='jq' for c in d['allow_candidates'])"
assert_json "git commit is an except candidate (count 3)" \
  "any(c['shape']=='git commit' and c['count']==3 for c in d['except_candidates'])"
assert_json "force push appears in deny summary (count 2)" \
  "any('force push' in s['reason'] and s['count']==2 for s in d['deny_summary'])"

echo "--- min-count filters low-frequency shapes ---"
python3 "$ANALYZE" --log "$LOG" --settings "$SETTINGS" --min-count 5 > "$OUT" 2>/dev/null
assert_json "gh pr view (count 4) dropped at min-count 5" \
  "all(c['shape']!='gh pr view' for c in d['allow_candidates'])"

echo "--- missing log exits non-zero with guidance ---"
TOTAL=$((TOTAL + 1))
if python3 "$ANALYZE" --log "$TMP/nope.jsonl" --settings "$SETTINGS" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: missing log should exit non-zero"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: missing log exits non-zero"
fi

echo "--- CLAUDEWATCH_LOG=off reports logging disabled ---"
TOTAL=$((TOTAL + 1))
# Sandbox HOME so the default path resolves to a nonexistent file, forcing the
# not-found branch; env off must produce the "disabled" guidance, not "no sessions".
OFFERR=$(CLAUDEWATCH_LOG=off HOME="$TMP" python3 "$ANALYZE" --settings "$SETTINGS" 2>&1 >/dev/null || true)
if echo "$OFFERR" | grep -qi "disabled"; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: CLAUDEWATCH_LOG=off reports logging disabled"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: CLAUDEWATCH_LOG=off reports logging disabled (got: ${OFFERR:-none})"
fi

rm -f "$LOG" "$SETTINGS" "$OUT"
rmdir "$TMP" 2>/dev/null || true

print_results
