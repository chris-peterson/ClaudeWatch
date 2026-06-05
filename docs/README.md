# <img src="favicon.svg" alt="ClaudeWatch" width="64" height="64" style="vertical-align: middle"> ClaudeWatch

A Claude Code plugin that enforces command safety rules via a `PreToolUse` hook.

Claude Code's built-in permission system uses naive string matching that [fails for compound commands, heredocs, and flag reordering](https://github.com/anthropics/claude-code/issues/30519). A block rule on `git push --force` won't catch `git push -f`. A block rule on `git commit` won't fire when the command is `git add . && git commit -m "oops"`.

`ClaudeWatch` solves this by intercepting every `Bash` tool call and matching against regex rules loaded from YAML config files. The engine auto-discovers all `*.yml` files in the `rules/` directory. Each file is a *rule set* — a group of patterns guarding one domain (git, secrets, package installs, and so on) — so adding protection for a new domain means dropping in another YAML file, with no engine change.

The shipped rule sets, and the exact commands each one blocks or asks about, are enumerated on the [rules](/rules) page, generated directly from the rules YAML.

For each matched command:

- **Block** — destructive operations are rejected outright
- **Ask** — mutating operations require user confirmation

> [!TIP]
> See the [rules](/rules) for the full list of protected commands.

## Example

The default configuration asks to confirm `git push`, but blocks `git push -f|--force`:

`❯ git push --force`

```text
⏺ Bash(git push --force)
  ⎿  PreToolUse:Bash hook returned blocking error
  ⎿  watch-git: overwrites shared remote history — https://git-scm.com/docs/git-push#Documentation/git-push.txt--f
```

`❯ git push`

presents a confirmation dialog --

```text
 Bash command

   git push
   Push to origin/main

 This command requires approval

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for: git push:*
   3. No
```

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

Rules are defined in YAML files under `rules/`. See the [rules](/rules) reference.

> [!NOTE]
> Use the `/ClaudeWatch:rules` skill to interactively view and edit rules.
