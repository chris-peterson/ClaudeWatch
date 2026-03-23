# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run tests
bash tests/test-watchdog.sh

# Test the plugin locally
claude --plugin-dir .
```

## Architecture

This is a Claude Code plugin that enforces Bash command safety via a `PreToolUse` hook. The core engine ("claude-watchdog") is generic and reusable — each rule set is a standalone YAML file with its own name, optional filter, and block/ask rules.

**Key files:**

- `scripts/watchdog.py` — the generic hook engine; loads all `*.yml` files from a rules directory, evaluates every rule set, and outputs a single coalesced JSON decision
- `rules/watch-git.yml` — git safety rules (block destructive ops, ask for mutating ops)
- `rules/watch-installs.yml` — install safety rules (block dangerous installs, ask for dependency changes)
- `rules/watch-files.yml` — filesystem safety rules (block rm -rf /, chmod 777, etc.)
- `rules/watch-secrets.yml` — secret exposure rules (block cat ~/.ssh/id_*, echo $SECRET_KEY, etc.)
- `skills/rules/SKILL.md` — interactive skill for viewing and editing rules; invocable as `/ClaudeWatch:rules`
- `hooks/hooks.json` — single `PreToolUse` (Bash) hook that points the engine at the `rules/` directory
- `.claude-plugin/plugin.json` — plugin manifest

**Hook protocol:** Claude Code passes tool invocations as JSON on stdin. The hook outputs `{"decision":"block",...}`, `{"decision":"ask",...}`, or nothing (allow). Exit code must always be 0.

**YAML format:** Each rules file has top-level `name`, optional `filter` (regex pre-check to skip irrelevant commands), and a `rules` map with `block`/`ask` lists. Each rule has `name`, `pattern`, `reason`, and `ref` fields. `watchdog.py` ships a minimal pure-Python parser — no external dependencies. See [docs/schema.md](docs/schema.md) for the full schema reference.

**Rule patterns** are Python regexes matched with `re.search()` (matches anywhere in the command string). This is the core safety advantage over Claude Code's built-in deny rules, which use `startsWith()` and miss compound commands like `git add . && git commit`.

## Design notes

Single repo, extensible by design. The engine (`scripts/watchdog.py`) is deliberately decoupled from any specific rule set. Each YAML file is self-contained with its own `name`, `filter`, and rules. To add a new safety domain, drop a YAML file in `rules/` — the engine auto-discovers all `*.yml` files at startup. To disable a rule set without deleting it, rename it to `*.yml.disabled`.

The repo ships starter rule sets (`watch-git`, `watch-installs`, `watch-files`, `watch-secrets`) and users can add their own alongside them.
