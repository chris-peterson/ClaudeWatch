#!/bin/bash
# Decision-log analyzer (scripts/analyze-decisions.py). Builds a synthetic log
# and asserts the two proposal buckets.
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

ANALYZE="$SCRIPT_DIR/../scripts/analyze-decisions.py"

echo "=== decision log analysis ==="

TMP=$(mktemp -d /tmp/cw-analyze.XXXXXX)
LOG="$TMP/decisions.jsonl"
OUT="$TMP/out.json"

# Synthetic log. Records carry the current `command_shape` field ([LOG-03]); the
# third `git commit` record keeps the legacy raw `command` field to prove the
# analyzer still reduces pre-change logs via its fallback path.
#   gh pr view  x4  allow                     -> no bucket (by_mode only)
#   jq          x5  allow                     -> no bucket (by_mode only)
#   git commit  x3  ask                       -> except_candidate
#   force push  x2  deny                      -> deny_summary
cat > "$LOG" <<'EOF'
{"schema":2}
{"ts":"2026-05-31T10:00:00+00:00","session":"s1","decision":"allow","tool":"Bash","mode":"auto","command_shape":"gh pr view","cwd":"/a"}
{"ts":"2026-05-31T10:01:00+00:00","decision":"allow","tool":"Bash","mode":"auto","command_shape":"gh pr view","cwd":"/a"}
{"ts":"2026-05-31T10:02:00+00:00","decision":"allow","tool":"Bash","mode":"auto","command_shape":"gh pr view","cwd":"/b"}
{"ts":"2026-05-31T10:03:00+00:00","decision":"allow","tool":"Bash","mode":"default","command":"gh pr view 4","cwd":"/b"}
{"ts":"2026-05-31T10:04:00+00:00","decision":"allow","tool":"Bash","command_shape":"jq","cwd":"/a"}
{"ts":"2026-05-31T10:05:00+00:00","decision":"allow","tool":"Bash","command_shape":"jq","cwd":"/a"}
{"ts":"2026-05-31T10:06:00+00:00","decision":"allow","tool":"Bash","command_shape":"jq","cwd":"/a"}
{"ts":"2026-05-31T10:06:30+00:00","decision":"allow","tool":"Bash","command":"OUT=/tmp/x jq .a f.json","cwd":"/a"}
{"ts":"2026-05-31T10:06:40+00:00","decision":"allow","tool":"Bash","command":"OUT=/tmp/y jq .b g.json","cwd":"/a"}
{"ts":"2026-05-31T10:07:00+00:00","session":"s2","decision":"ask","tool":"Bash","command_shape":"git commit","matched":["watch-git — git commit"],"cwd":"/a"}
{"ts":"2026-05-31T10:08:00+00:00","decision":"ask","tool":"Bash","command_shape":"git commit","matched":["watch-git — git commit"],"cwd":"/a"}
{"ts":"2026-05-31T10:09:00+00:00","decision":"ask","tool":"Bash","command":"GIT_TRACE=1 git commit -m wip","matched":["watch-git — git commit"],"cwd":"/a"}
{"ts":"2026-05-31T10:10:00+00:00","decision":"deny","tool":"Bash","command_shape":"git push","matched":["watch-git — force push"],"cwd":"/a"}
{"ts":"2026-05-31T10:11:00+00:00","decision":"deny","tool":"Bash","command_shape":"git push","matched":["watch-git — force push"],"cwd":"/a"}
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

python3 "$ANALYZE" --log "$LOG" --min-count 2 > "$OUT" 2>/dev/null

assert_json "allow records propose nothing" \
  "set(d) == {'except_candidates', 'deny_summary', 'by_mode', 'meta'}"
assert_json "gh pr view (allowed) is in no bucket" \
  "all(c['shape']!='gh pr view' for c in d['except_candidates'])"
assert_json "by_mode tallies auto and default" \
  "d['by_mode'].get('auto')==3 and d['by_mode'].get('default')==1"
assert_json "schema header is skipped (14 records, not counted in by_mode)" \
  "d['meta']['records_considered']==14 and d['by_mode'].get('unspecified')==10"
assert_json "meta reports distinct sessions (s1, s2)" \
  "d['meta']['distinct_sessions']==2"
assert_json "meta reports the oldest and newest record ts" \
  "d['meta']['oldest_ts']=='2026-05-31T10:00:00+00:00' and d['meta']['newest_ts']=='2026-05-31T10:11:00+00:00'"
assert_json "meta reports the span in days" \
  "d['meta']['span_days']==0.01"
assert_json "git commit is an except candidate (count 3)" \
  "any(c['shape']=='git commit' and c['count']==3 for c in d['except_candidates'])"
assert_json "force push appears in deny summary (count 2)" \
  "any('force push' in s['reason'] and s['count']==2 for s in d['deny_summary'])"

echo "--- min-count filters low-frequency shapes ---"
python3 "$ANALYZE" --log "$LOG" --min-count 4 > "$OUT" 2>/dev/null
assert_json "git commit (count 3) dropped at min-count 4" \
  "all(c['shape']!='git commit' for c in d['except_candidates'])"

echo "--- records with matched_shapes group by the part each rule matched ---"
# A chain logs its leading command as command_shape; the rule fired on a later
# part, which matched_shapes names. The compound note (null shape) takes the
# first rule's shape.
cat > "$LOG" <<'EOF'
{"schema":2}
{"ts":"2026-05-31T10:00:00+00:00","decision":"deny","tool":"Bash","command_shape":"cat","matched":["compound command: escalated","git commit: creates a permanent commit"],"matched_shapes":[null,"git commit"]}
{"ts":"2026-05-31T10:01:00+00:00","decision":"deny","tool":"Bash","command_shape":"echo","matched":["rm -rf: recursively deletes"],"matched_shapes":["rm"]}
{"ts":"2026-05-31T10:02:00+00:00","decision":"ask","tool":"Bash","command_shape":"git stash","matched":["git stash: modifies the stash stack"],"matched_shapes":["git stash"]}
{"ts":"2026-05-31T10:03:00+00:00","decision":"ask","tool":"Bash","command_shape":"git stash","matched":["git stash: modifies the stash stack"]}
EOF
python3 "$ANALYZE" --log "$LOG" --min-count 1 > "$OUT" 2>/dev/null
assert_json "deny sample is the matched part (git commit), not the leading cat" \
  "any(s['reason'].startswith('git commit') and s['samples']==['git commit'] for s in d['deny_summary'])"
assert_json "compound note samples the rule's part" \
  "any(s['reason'].startswith('compound') and s['samples']==['git commit'] for s in d['deny_summary'])"
assert_json "rm -rf deny samples rm, not echo" \
  "any(s['reason'].startswith('rm -rf') and s['samples']==['rm'] for s in d['deny_summary'])"
assert_json "ask records with and without matched_shapes group together" \
  "any(c['shape']=='git stash' and c['count']==2 for c in d['except_candidates'])"
assert_json "no group is keyed by the leading command" \
  "all(c['shape'] not in ('cat','echo') for c in d['except_candidates']) and all('cat' not in s['samples'] for s in d['deny_summary'])"

echo "--- missing log exits non-zero with guidance ---"
TOTAL=$((TOTAL + 1))
if python3 "$ANALYZE" --log "$TMP/nope.jsonl" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: missing log should exit non-zero"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: missing log exits non-zero"
fi

echo "--- CLAUDEWATCH_LOG=off reports logging disabled ---"
TOTAL=$((TOTAL + 1))
# Sandbox HOME so the default path resolves to a nonexistent file, forcing the
# not-found branch; env off must produce the "disabled" guidance, not "no sessions".
OFFERR=$(CLAUDEWATCH_LOG=off HOME="$TMP" python3 "$ANALYZE" 2>&1 >/dev/null || true)
if echo "$OFFERR" | grep -qi "disabled"; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: CLAUDEWATCH_LOG=off reports logging disabled"
else
  FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: CLAUDEWATCH_LOG=off reports logging disabled (got: ${OFFERR:-none})"
fi

rm -f "$TMP"/*
rmdir "$TMP" 2>/dev/null || true

print_results
