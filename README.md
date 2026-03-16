# git-guardian

A Claude Code plugin that enforces git safety rules as a `PreToolUse` hook.

Claude Code's built-in permission system uses naive string matching that [fails for compound commands, heredocs, and flag reordering](https://github.com/anthropics/claude-code/issues/30519). A deny rule on `git push --force` won't catch `git push -f`. A deny rule on `git commit` won't fire when the command is `git add . && git commit -m "oops"`.

A [security report](https://github.com/anthropics/claude-code/issues/13371) demonstrated complete bypass via command chaining and option insertion. The [meta-issue](https://github.com/anthropics/claude-code/issues/30519) tracks 30+ open bugs.

`git-guardian` solves this by intercepting every `Bash` tool call and matching against rules loaded from `rules.yml`:

- **Block** — destructive operations are rejected outright
- **Ask** — mutating operations require user confirmation

## Example

The default configuration asks to confirm `git push`, but it blocks `git push -f|--force`

`❯ git push --force`

```text
⏺ Bash(git push --force)
  ⎿  PreToolUse:Bash hook returned blocking error
  ⎿  git-guard: overwrites shared remote history — https://git-scm.com/docs/git-push#Documentation/git-push.txt--f
  ⎿  Error: git-guard: overwrites shared remote history — https://git-scm.com/docs/git-push#Documentation/git-push.txt--f

⏺ The git-guard hook is blocking the force-push because it's configured to protect shared remote history on main.
```

`❯ git push`

presents a confirmation dialog --
```text
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command

   git push
   Push to origin/main

 This command requires approval

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don’t ask again for: git push:*
   3. No
```

⬇️

```text
⏺ Bash(git push)
  ⎿  PreToolUse:Bash hook error
  ⎿  To gitlab.getty.cloud:cpeterson/ai-sdlc.git
        c8f457c..971f77d  main -> main

⏺ Pushed.
```

## Requirements

Python 3 (standard library only — no third-party packages required).

## Installation

```bash
claude plugin marketplace add https://github.com/chris-peterson/git-guardian
claude plugin install git-guardian
```

Or load directly for a single session without installing:

```bash
git clone https://github.com/chris-peterson/git-guardian
claude --plugin-dir ./git-guardian
```

## Configuration

Rules are defined in `rules.yml`. Each rule has a `pattern` (Python regex matched anywhere in the command string), a `reason` (shown in the block/ask message), and a `ref` (git documentation link).

```yaml
rules:
  deny:
    - pattern: 'git\s+push\s.*(--force|-[a-zA-Z]*f\b)'
      reason: rewrites remote history
      ref: https://git-scm.com/docs/git-push#Documentation/git-push.txt--f
    # ...
  ask:
    - pattern: 'git\s+commit(\s|$)'
      reason: creates a permanent commit
      ref: https://git-scm.com/docs/git-commit
    # ...
```

## Testing

```bash
bash tests/test-git-guard.sh
```

50 test cases covering block, ask, and allow scenarios including compound commands.

## Why a hook instead of built-in deny rules

The key advantage: Python's `re.search()` matches anywhere in the command string, so `git add . && git commit` correctly triggers the `add` rule on the first match. No compound command bypass. No flag reordering bypass.

## References

- [Claude Code committed code despite explicit deny](https://github.com/anthropics/claude-code/issues/27040#issuecomment-4028746897) — firsthand incident report: deny rules in `settings.json` silently failed on a `git commit` with heredoc syntax, with two independent safeguards (deny rule + skill instruction) both bypassed
- [Permission system meta-issue](https://github.com/anthropics/claude-code/issues/30519) — tracks 30+ open bugs in Claude Code's built-in permission matching
- [Security bypass report](https://github.com/anthropics/claude-code/issues/13371) — demonstrated complete bypass via command chaining and option insertion

## Acknowledgements

Inspired by a component of [Boucle Framework](https://framework.boucle.sh), [git-safe](https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/git-safe)
