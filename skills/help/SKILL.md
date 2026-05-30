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
| `watch-aws` | AWS CLI ops by reversibility — `delete-`/`remove-`/`deregister-`/`terminate-`/`purge-`/`reset-`/`revoke-`, `release-address`, `s3 rm`/`rb` (block); other mutating ops (ask); `get-`/`list-`/`describe-`/`head-` and `s3 ls` allowed |
| `watch-bash` | Shell-script destructive primitives in `.sh`/`.bash`/`.zsh` file content (`rm -rf /`, `curl\|sh`, `dd of=/dev/sd*`, `mkfs`, `shred`, `chmod 777`, `chown -R`) — bash-target coverage lives in `watch-files` |
| `watch-dotnet` | .NET decompilers, `.nupkg` downloads/extraction, `nuget install` — nudges toward SourceLink |
| `watch-files` | `rm -rf /`, `chmod 777`, shred, recursive chmod/chown |
| `watch-git` | Destructive (force push, branch -D) and mutating (add, commit, push, reset --hard, force-with-lease) git ops |
| `watch-installs` | `curl \| sh`, global installs, sudo pip/apt, npm/yarn/pip dependency changes |
| `watch-node` | Node/JS destructive primitives (`fs.rmSync`, `child_process.exec`, `new Function`, `vm.runInThisContext`, `eval`) — inline (`node -e`/`bun`/`deno`/`tsx`) and in `.js`/`.mjs`/`.cjs`/`.ts`/`.mts`/`.cts` files |
| `watch-pwsh` | PowerShell destructive primitives (`Format-Volume`, `Restart-Computer`, `IWR \| iex`, `Remove-Item -Recurse -Force`) — inline and in `.ps1`/`.psm1`/`.psd1` files |
| `watch-python` | Python destructive primitives (`shutil.rmtree`, `pickle.loads`, `os.system`, `subprocess shell=True`, `eval`, `exec`) — inline and in `.py` files |
| `watch-ruby` | Ruby destructive primitives (`FileUtils.rm_rf`, `Marshal.load`, `YAML.load`, `system`/`exec`, backtick exec with interpolation, `eval`, `instance_eval`) — inline (`ruby -e`) and in `.rb` files |
| `watch-secrets` | SSH keys, cloud credentials, echoed env vars, dotfile reads |

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
