# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run tests
bash tests/test-git-guard.sh

# Test the plugin locally
claude --plugin-dir .
```

## Architecture

This is a Claude Code plugin that enforces git safety as a `PreToolUse` hook.

**Key files:**

- `rules.yml` — the editable rule configuration (deny/ask sections)
- `scripts/git-guard.py` — the hook implementation; reads `rules.yml`, matches the incoming Bash command against rules, and outputs a JSON decision
- `scripts/first-run.sh` — `SessionStart` hook; emits a configure invitation on first session (no `~/.claude/.git-guardian-configured` marker)
- `skills/configure/SKILL.md` — interactive configure skill; invocable as `/git-guardian:configure`
- `hooks/hooks.json` — wires `PreToolUse` (Bash) and `SessionStart` hooks using `${CLAUDE_PLUGIN_ROOT}`
- `.claude-plugin/plugin.json` — plugin manifest

**Hook protocol:** Claude Code passes tool invocations as JSON on stdin. The hook outputs `{"decision":"block",...}`, `{"decision":"ask",...}`, or nothing (allow). Exit code must always be 0.

**YAML parser:** `git-guard.py` ships a minimal pure-Python parser for `rules.yml` — no external dependencies. Each rule has `pattern`, `reason`, and `ref` fields. If the format needs to change, update `parse_rules_yml()` in `scripts/git-guard.py` alongside `rules.yml`.

**Rule patterns** are Python regexes matched with `re.search()` (matches anywhere in the command string). This is the core safety advantage over Claude Code's built-in deny rules, which use `startsWith()` and miss compound commands like `git add . && git commit`.
