#!/bin/bash
# Manual probe: what does the *host* do with an emitted `ask`?
#
# Not part of `tests/test-watchdog.sh`. It spawns real Claude Code sessions, so
# it is slow and costs tokens. Run it when a Claude Code release claims to change
# permission or hook behavior, and record the result in SPEC.md [OUT-04] — that
# requirement describes the host's half of the contract, which no unit test can
# observe and which a changelog entry has already been wrong about
# (2.1.257 named `permissions.ask` rules; the hook path was unaffected).
#
#   bash tests/probe-host-ask-behavior.sh
#
# Method: run an ask-tier command with an observable side effect (`chmod` on a
# throwaway file) under each permission mode, then read the file's mode back. If
# it changed, the `ask` was dropped and the command ran. If it didn't, the `ask`
# stopped it. The hook's own decision is read from the decision log so a run
# where the hook never fired is reported as such rather than scored.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/claudewatch-hostprobe.XXXXXX")"
LOG="$WORK/decisions.jsonl"

trap 'rm -rf "$WORK"' EXIT

command -v claude >/dev/null 2>&1 || { echo "claude not on PATH"; exit 1; }
echo "Claude Code $(claude --version)"
echo "plugin: $PLUGIN_ROOT"
echo ""

perm_of() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode)[-3:])' "$1"; }

probe() {
  local label="$1"; shift
  local target="$WORK/target-${label// /_}.txt"
  echo probe > "$target"
  chmod 600 "$target"

  CLAUDEWATCH_LOG="$LOG" claude --plugin-dir "$PLUGIN_ROOT" "$@" \
    -p "run exactly this bash command and nothing else: chmod 644 $target" \
    >/dev/null 2>&1

  local graded="no"
  [ -f "$LOG" ] && grep -q '"decision":"ask"' "$LOG" && graded="yes"
  : > "$LOG"

  if [ "$graded" = "no" ]; then
    printf '  %-44s %s\n' "$label" "INCONCLUSIVE — the hook never graded it"
    return
  fi
  if [ "$(perm_of "$target")" = "644" ]; then
    printf '  %-44s %s\n' "$label" "ask DROPPED — the command ran unconfirmed"
  else
    printf '  %-44s %s\n' "$label" "ask HELD — the command did not run"
  fi
}

# Headless only: `claude -p` is the sole scriptable surface, so every row here
# describes a headless session. Interactive behavior differs — an interactive
# `auto` session drops the ask and runs the command, which is the case this
# whole probe exists to keep an eye on and the one a script cannot reach. Check
# that one by hand: run a guarded command in an interactive `auto` session and
# see whether you are asked.
echo "Headless (--print) sessions:"
for mode in auto default acceptEdits plan bypassPermissions manual dontAsk; do
  probe "$mode" --permission-mode "$mode"
done
probe "auto + --permission-prompts none" --permission-mode auto --permission-prompts none

echo ""
echo 'Interactive sessions are not scriptable — check auto by hand (see comment above).'
