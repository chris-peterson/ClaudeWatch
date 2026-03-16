# git-guardian

A Claude Code plugin that enforces git safety rules via a `PreToolUse` hook.

Claude Code's built-in permission system uses naive string matching that [fails for compound commands, heredocs, and flag reordering](https://github.com/anthropics/claude-code/issues/30519). A block rule on `git push --force` won't catch `git push -f`. A block rule on `git commit` won't fire when the command is `git add . && git commit -m "oops"`.

`git-guardian` solves this by intercepting every `Bash` tool call and matching against regex rules loaded from `rules.yml`:

- **Block** — destructive operations are rejected outright
- **Ask** — mutating operations require user confirmation

> [!TIP]
> See the [default rules](/rules) for the full list of protected commands.

## Example

The default configuration asks to confirm `git push`, but blocks `git push -f|--force`:

`❯ git push --force`

```text
⏺ Bash(git push --force)
  ⎿  PreToolUse:Bash hook returned blocking error
  ⎿  git-guard: overwrites shared remote history — https://git-scm.com/docs/git-push#Documentation/git-push.txt--f
  ⎿  Error: git-guard: overwrites shared remote history — https://git-scm.com/docs/git-push#Documentation/git-push.txt--f

⏺ The git-guard hook is blocking the force-push because it's configured to protect shared remote history on main.
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

```text
⏺ Bash(git push)
  ⎿  To gitlab.getty.cloud:cpeterson/ai-sdlc.git
        c8f457c..971f77d  main -> main

⏺ Pushed.
```

## Installation

```bash
claude plugin marketplace add https://github.com/chris-peterson/git-guardian
claude plugin install git-guardian
```

Or load directly for a single session:

```bash
git clone https://github.com/chris-peterson/git-guardian
claude --plugin-dir ./git-guardian
```

## Customization

Rules are defined in `rules.yml` at the plugin root. See the [default rules](/rules) reference and the full [rules.yml](/rules-yml) listing.

> [!NOTE]
> Use the `/git-guardian:rules` skill to interactively view and edit rules.
