# git-guardian

A Claude Code plugin that enforces git safety rules via a `PreToolUse` hook.

Claude Code's built-in permission system uses naive string matching that [fails for compound commands, heredocs, and flag reordering](https://github.com/anthropics/claude-code/issues/30519). `git-guardian` solves this with Python regex rules matched anywhere in the command string via `re.search()`.

## Installation

```bash
claude plugin marketplace add https://github.com/chris-peterson/git-guardian
claude plugin install git-guardian
```

## Documentation

See the [docs site](https://chris-peterson.github.io/git-guardian/) for usage, configuration, and the full [default rules](https://chris-peterson.github.io/git-guardian/#/rules) reference.

## Development

```bash
just test                          # run the test suite
just docs                          # regenerate docs from rules.yml
just rules                         # interactive rules editor
claude --plugin-dir .              # test the plugin locally
```

## References

- [Claude Code committed code despite explicit deny](https://github.com/anthropics/claude-code/issues/27040#issuecomment-4028746897)
- [Permission system meta-issue](https://github.com/anthropics/claude-code/issues/30519)
- [Security bypass report](https://github.com/anthropics/claude-code/issues/13371)
- Inspired by [git-safe](https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/git-safe) from [Boucle Framework](https://framework.boucle.sh)
