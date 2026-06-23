# <img src="favicon.svg" alt="ClaudeWatch" width="64" height="64" style="vertical-align: middle"> ClaudeWatch

A Claude Code plugin that enforces command safety rules via a `PreToolUse` hook.

Claude Code's built-in permission system uses naive string matching that [fails for compound commands, heredocs, and flag reordering](https://github.com/anthropics/claude-code/issues/30519). A block rule on `git push --force` won't catch `git push -f`. A block rule on `git commit` won't fire when the command is `git add . && git commit -m "oops"`.

`ClaudeWatch` solves this by intercepting every `Bash` tool call — and the code Claude writes to disk via `Write`/`Edit` — and matching against regex rules loaded from YAML config files. The engine auto-discovers all `*.yml` files in the `watches/` directory. Each file is a *rule set* — a group of patterns guarding one domain (git, secrets, package installs, and so on) — so adding protection for a new domain means dropping in another YAML file, with no engine change.

The shipped rule sets, and the exact commands each one blocks or asks about, are enumerated on the [rules](/rules) page, generated directly from the rules YAML.

For each matched command:

- **Block** — destructive operations are rejected outright
- **Ask** — mutating operations require user confirmation

> [!TIP]
> See the [rules](/rules) for the full list of protected commands.

## In action

ClaudeWatch works on its own — it screens every command, and the code Claude writes to disk, blocking the genuinely dangerous and asking before anything that changes state. Here a force-push is blocked outright and a recursive delete pauses for confirmation:

<div class="cw-session" data-cw-session="session"></div>

## The skills

Most of the time ClaudeWatch stays out of the way. When you want to look under the hood — see what's guarding your commands, or tune the rules from what's been prompting you — two skills help:

<div class="cw-session" data-cw-session="examples"></div>

## Installation

```bash
claude plugin marketplace add chris-peterson/claude-marketplace
claude plugin install ClaudeWatch@chris-peterson
```

Or load directly for a single session:

```bash
git clone https://github.com/chris-peterson/ClaudeWatch
claude --plugin-dir ./ClaudeWatch
```

## Customization

Rules are defined in YAML files under `watches/`. See the [rules](/rules) reference.

> [!NOTE]
> Use the `/ClaudeWatch:rules` skill to interactively view and edit rules.
