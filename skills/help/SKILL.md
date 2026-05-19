---
description: >
  Show a ClaudeWatch overview — what it does, the rule sets it ships, the
  available commands, and where to find full docs. Invoke when the user asks
  "what does ClaudeWatch do?", "how do I use ClaudeWatch?", or types
  /ClaudeWatch:help.
---

# ClaudeWatch

A `PreToolUse` Bash hook that enforces command safety using Python regex rules
matched with `re.search()`. Catches compound commands (`git add . && git commit`),
heredocs, and reordered flags that Claude Code's built-in `startsWith()` deny
rules miss.

## Rule sets

| Name | Guards |
|---|---|
| `watch-git` | Destructive (force push, reset --hard, branch -D) and mutating (add, commit, push) git ops |
| `watch-installs` | `curl \| sh`, global installs, sudo pip/apt, npm/yarn/pip dependency changes |
| `watch-files` | `rm -rf /`, `chmod 777`, shred, recursive chmod/chown |
| `watch-secrets` | SSH keys, cloud credentials, echoed env vars, dotfile reads |
| `watch-pwsh` | PowerShell destructive primitives (`Format-Volume`, `Restart-Computer`, `IWR \| iex`, `Remove-Item -Recurse -Force`) — inline and in `.ps1`/`.psm1`/`.psd1` files |
| `watch-python` | Python destructive primitives (`shutil.rmtree`, `pickle.loads`, `os.system`, `subprocess shell=True`, `eval`, `exec`) — inline and in `.py` files |
| `watch-dotnet` | .NET decompilers, `.nupkg` downloads/extraction, `nuget install` — nudges toward SourceLink |

Rules live in `rules/*.yml`. Disable a set by renaming to `*.yml.disabled`.
Add a set by dropping a new `watch-*.yml` file in the same directory — the
engine auto-discovers it.

## Commands

| Command | What it does |
|---|---|
| `/ClaudeWatch:help` | Show this overview |
| `/ClaudeWatch:rules` | View and interactively edit rules |
| `/ClaudeWatch:rules --list` | List rules without entering the edit loop |

## Decisions

When a Bash invocation matches a rule, the hook emits one of:

- **block** — command rejected with the rule's reason
- **ask** — prompt the user to confirm
- (silent) — no rule matched, command runs normally

## Docs

- Reference site: https://chris-peterson.github.io/ClaudeWatch/
- YAML schema: https://chris-peterson.github.io/ClaudeWatch/#/schema
- Default rules: https://chris-peterson.github.io/ClaudeWatch/#/rules
- Source: https://github.com/chris-peterson/ClaudeWatch
