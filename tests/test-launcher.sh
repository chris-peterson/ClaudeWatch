#!/bin/bash
# Tests for the PreToolUse interpreter launcher (hooks/run-watchdog.sh,
# [HK-05], [PL-02], [PL-03]). The launcher resolves a Python interpreter at run
# time and execs the engine; on resolution failure it fails loudly with no
# fabricated decision.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$PLUGIN_ROOT/hooks/run-watchdog.sh"

PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $1"; }

echo "Running launcher tests..."

# 1. End-to-end: a known block command run through the launcher produces a deny.
#    This exercises interpreter resolution + exec of the engine, not just the
#    engine in isolation.
block_input='{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
out=$(printf '%s' "$block_input" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDEWATCH_LOG=off bash "$LAUNCHER" 2>/dev/null || true)
if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
  pass "launcher resolves an interpreter and runs the engine (deny on block command)"
else
  fail "launcher should emit deny for a block command (got: ${out:-empty})"
fi

# 2. A non-matching command produces no output (allow-by-silence), proving the
#    launcher forwards the engine's allow path rather than fabricating output.
allow_input='{"tool_name":"Bash","tool_input":{"command":"git status"}}'
out=$(printf '%s' "$allow_input" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDEWATCH_LOG=off bash "$LAUNCHER" 2>/dev/null || true)
if [ -z "$out" ]; then
  pass "launcher forwards the engine's allow-by-silence (no output)"
else
  fail "launcher should produce no output for an allowed command (got: $out)"
fi

# 3. Resolution failure is loud and produces no decision ([PL-02], [PL-03]).
#    Point PATH at a directory that holds no interpreter so the launcher's
#    `command -v` finds none. A nonexistent directory (rather than the empty
#    string) is used on purpose: bash falls back to a compiled-in default PATH
#    when PATH is empty or unset, which would let an interpreter resolve and
#    defeat the test. The launcher's own bash is invoked by absolute path so the
#    restricted PATH blocks only the interpreter probe, not the launcher itself.
no_python_path="/nonexistent-claudewatch-launcher-test"
bash_bin="$(command -v bash)"
stdout_file="$(mktemp "${TMPDIR:-/tmp}/claudewatch-launcher-stdout.XXXXXX")"
stderr_file="$(mktemp "${TMPDIR:-/tmp}/claudewatch-launcher-stderr.XXXXXX")"
set +e
printf '%s' "$block_input" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDEWATCH_LOG=off PATH="$no_python_path" "$bash_bin" "$LAUNCHER" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e
out_on_fail="$(<"$stdout_file")"
err_on_fail="$(<"$stderr_file")"
rm -f "$stdout_file" "$stderr_file"

if [ "$rc" -ne 0 ]; then
  pass "launcher exits non-zero when no interpreter resolves"
else
  fail "launcher should exit non-zero when no interpreter resolves (got rc=$rc)"
fi

if [ -z "$out_on_fail" ]; then
  pass "launcher emits no decision on resolution failure (no fallback)"
else
  fail "launcher must not fabricate a decision on failure (got: $out_on_fail)"
fi

if printf '%s' "$err_on_fail" | grep -q "no Python interpreter found"; then
  pass "launcher reports the resolution failure on stderr"
else
  fail "launcher should report the failure on stderr (got: ${err_on_fail:-empty})"
fi

# 4. PowerShell launcher (hooks/run-watchdog.ps1) — the native-Windows path.
#    Exercised wherever pwsh is available (any platform); skipped cleanly when
#    it isn't, so the suite stays green on a host without PowerShell. The
#    native-Windows shell-dispatch question is settled by the windows-latest CI
#    job; this case proves the .ps1 launcher's resolution and fail-loud logic
#    against a real PowerShell.
PS_LAUNCHER="$PLUGIN_ROOT/hooks/run-watchdog.ps1"
if command -v pwsh >/dev/null 2>&1; then
  ps_out=$(printf '%s' "$block_input" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDEWATCH_LOG=off pwsh -NoProfile -File "$PS_LAUNCHER" 2>/dev/null || true)
  if printf '%s' "$ps_out" | grep -q '"permissionDecision":"deny"'; then
    pass "ps1 launcher resolves an interpreter and runs the engine (deny on block command)"
  else
    fail "ps1 launcher should emit deny for a block command (got: ${ps_out:-empty})"
  fi

  pwsh_bin="$(command -v pwsh)"
  ps_stdout_file="$(mktemp "${TMPDIR:-/tmp}/claudewatch-ps-stdout.XXXXXX")"
  ps_stderr_file="$(mktemp "${TMPDIR:-/tmp}/claudewatch-ps-stderr.XXXXXX")"
  set +e
  printf '%s' "$block_input" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDEWATCH_LOG=off PATH="$no_python_path" "$pwsh_bin" -NoProfile -File "$PS_LAUNCHER" >"$ps_stdout_file" 2>"$ps_stderr_file"
  ps_rc=$?
  set -e
  ps_out_on_fail="$(<"$ps_stdout_file")"
  ps_err_on_fail="$(<"$ps_stderr_file")"
  rm -f "$ps_stdout_file" "$ps_stderr_file"

  if [ "$ps_rc" -ne 0 ] && [ -z "$ps_out_on_fail" ] && printf '%s' "$ps_err_on_fail" | grep -q "no Python interpreter found"; then
    pass "ps1 launcher fails loud with no fabricated decision when no interpreter resolves"
  else
    fail "ps1 launcher should fail loud and emit no decision (rc=$ps_rc, out=${ps_out_on_fail:-empty}, err=${ps_err_on_fail:-empty})"
  fi
else
  echo "  SKIP: PowerShell (pwsh) not available; ps1 launcher cases skipped"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
