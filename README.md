# ClaudeWatch

A Claude Code plugin that enforces command safety rules via a `PreToolUse` hook.

Claude Code's built-in permission system uses naive string matching that [fails for compound commands, heredocs, and flag reordering](https://github.com/anthropics/claude-code/issues/30519). `ClaudeWatch` solves this with Python regex rules matched anywhere in the command string via `re.search()`.

## Rule Sets

The plugin ships four rule sets, each a standalone YAML file auto-discovered by the `watchdog` engine:

| Rule set | File | What it guards |
| --- | --- | --- |
| **watch-git** | `rules/watch-git.yml` | Force push, reset --hard, branch -D, and other destructive git ops (block); add, commit, push, and other mutating ops (ask) |
| **watch-installs** | `rules/watch-installs.yml` | curl\|sh, global installs, sudo pip/apt (block); npm install, yarn add, pip install, and other dependency changes (ask) |
| **watch-files** | `rules/watch-files.yml` | rm -rf /, chmod 777, shred, mv /dev/null (block); rm -rf, recursive chmod/chown (ask) |
| **watch-secrets** | `rules/watch-secrets.yml` | cat SSH keys, cloud credentials, echo secrets (block); cat dotfiles, .env files, env/printenv (ask) |

Each rule set has an optional `filter` regex that short-circuits commands that clearly don't apply (e.g. non-git commands skip the git rules entirely). To add a new rule set, drop a YAML file in `rules/`. To disable one, rename it to `*.yml.disabled`.

## Installation

```bash
claude plugin marketplace add https://github.com/chris-peterson/ClaudeWatch
claude plugin install ClaudeWatch
```

## Documentation

See the [docs site](https://chris-peterson.github.io/ClaudeWatch/) for usage, configuration, and the full [default rules](https://chris-peterson.github.io/ClaudeWatch/#/rules) reference.

## Development

```bash
just test                          # run the test suite
just docs                          # regenerate docs from rules
just rules                         # interactive rules editor
claude --plugin-dir .              # test the plugin locally
```

## References

- [Claude Code committed code despite explicit deny](https://github.com/anthropics/claude-code/issues/27040#issuecomment-4028746897)
- [Permission system meta-issue](https://github.com/anthropics/claude-code/issues/30519)
- [Security bypass report](https://github.com/anthropics/claude-code/issues/13371)
- Inspired by [git-safe](https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/git-safe) from [Boucle Framework](https://framework.boucle.sh)
