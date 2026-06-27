# <img src="docs/favicon.svg" alt="ClaudeWatch" width="64" height="64"> ClaudeWatch

A Claude Code plugin that enforces command and script safety rules via a `PreToolUse` hook on `Bash`, `Write`, and `Edit`.

Claude Code's built-in permission system uses naive string matching that [fails for compound commands, heredocs, and flag reordering](https://github.com/anthropics/claude-code/issues/30519). `ClaudeWatch` solves this with regex rules matched anywhere in the command string (or in the body of a script being written/edited) — find-anywhere, no implicit anchoring.

## Rule Sets

The plugin ships these rule sets, each a standalone YAML file auto-discovered by the `watchdog` engine:

| Rule set | File | What it guards |
| --- | --- | --- |
| **watch-aws** | `watches/watch-aws.yml` | `aws … delete-`/`remove-`/`deregister-`/`terminate-`/`purge-`/`reset-`/`revoke-` ops, `release-address`, `s3 rm`/`s3 rb` (block); any other `aws` mutating operation (ask). Read-only `get-`/`list-`/`describe-`/`head-` ops and `s3 ls` are allowed. Matches through interspersed global flags (`aws --profile prod ec2 …`) |
| **watch-bash** | `watches/watch-bash.yml` | `rm -rf /`, `curl \| sh`, `dd of=/dev/sd*`, `mkfs /dev/*`, `shred` (block); `rm -rf` outside cache/tmp paths, `chmod 777`, `chown -R`, shell `eval` of dynamic strings (ask). Applies to `.sh`/`.bash`/`.zsh` file content authored via Write/Edit (bash-target rules for the same primitives live in watch-files) |
| **watch-dotnet** | `watches/watch-dotnet.yml` | .NET decompilers (`ilspycmd`, `ildasm`, `dotpeek`, `dnspy[ex]`, `justdecompile`), unzip/tar of `.nupkg`, curl/wget of `.nupkg`, and `nuget install` (ask). Nudges toward SourceLink instead of decompiling NuGet packages |
| **watch-files** | `watches/watch-files.yml` | rm -rf /, chmod 777, shred, mv /dev/null (block); rm -rf, recursive chmod/chown (ask) |
| **watch-git** | `watches/watch-git.yml` | Force push and other no-recovery git ops (block); commit, push, push --delete, reset --hard, branch -D, force-with-lease, and other recoverable mutating ops (ask). Stage-only ops (add, rm, non-hard reset) are allowed |
| **watch-installs** | `watches/watch-installs.yml` | curl\|sh, global installs, sudo pip/apt (block); npm install, yarn add, pip install, and other dependency changes (ask) |
| **watch-node** | `watches/watch-node.yml` | `fs.rmSync` at root/$HOME, `child_process.exec("rm -rf /")`, `new Function(...)` (block); `fs.unlink`, `fs.rm({recursive:true})`, `exec`/`execSync`, `vm.runIn*Context`, `eval` (ask). Applies to both `node -e`/`bun -e`/`deno`/`tsx` bash invocations and `.js`/`.mjs`/`.cjs`/`.ts`/`.mts`/`.cts` file content authored via Write/Edit |
| **watch-pwsh** | `watches/watch-pwsh.yml` | Format-Volume, Restart-Computer, IWR \| iex (block); Remove-Item -Recurse -Force, Stop-Process -Force, Out-File to sensitive paths (ask). Applies to both `pwsh -Command "..."` bash invocations and `.ps1`/`.psm1`/`.psd1` file content authored via Write/Edit |
| **watch-python** | `watches/watch-python.yml` | shutil.rmtree at root/$HOME, pickle.loads, `__import__('os').system`, subprocess shell=True with destructive payload (block); eval, exec, os.system, os.remove, generic shell=True (ask). Applies to both `python3 -c "..."` bash invocations and `.py` file content authored via Write/Edit |
| **watch-ruby** | `watches/watch-ruby.yml` | `FileUtils.rm_rf` at root/$HOME, `Marshal.load`, `YAML.load` on input (block); `FileUtils.rm_rf`, `File.delete`, `system`/`exec`, backtick-with-interpolation, `eval`, `instance_eval`/`class_eval`/`module_eval` (ask). Applies to both `ruby -e` bash invocations and `.rb` file content authored via Write/Edit |
| **watch-secrets** | `watches/watch-secrets.yml` | cat SSH keys, cloud credentials, echo secrets (block); cat dotfiles, .env files, env/printenv (ask) |

Each rule set has an optional `filter` regex that short-circuits bash commands outside its domain. Rule sets targeting script bodies declare `extensions` to gate which `Write`/`Edit` payloads they evaluate. To add a new rule set, drop a YAML file in `watches/`. To disable one, rename it to `*.yml.disabled`.

## Pairing with Bash permissions

Agents routinely generate one-off scripts to complete tasks — both inline (`python3 -c "..."`, `pwsh -Command "..."`) and as authored files (`Write` of a `.py` or `.ps1`). Reviewing every such invocation through a permission prompt is impractical: the script body is opaque in the prompt, and clicking "allow" doesn't reflect real consent.

ClaudeWatch's regex matching reaches anywhere in the command string and into the body of `Write`/`Edit` payloads, which covers cases Claude Code's built-in `startsWith` rules can't see. That makes it safe to broaden your Bash allowlist for the interpreters agents reach for, and let ClaudeWatch be the safety net that blocks destructive variants (`shutil.rmtree` at filesystem roots, `Format-Volume`, `Invoke-WebRequest | iex`, etc.):

```jsonc
// .claude/settings.json
{
  "permissions": {
    "allow": [
      "Bash(aws *)",
      "Bash(pwsh *)",
      "Bash(python3 *)"
    ]
  }
}
```

Broadening the allowlist is safe because a hook decision outranks an `allow` rule: ClaudeWatch's `ask` and `deny` still fire even when your allowlist would otherwise let the command through. The allow rule only takes effect where ClaudeWatch stays silent — a silent hook defers to Claude Code's normal permission flow rather than auto-approving.

One nuance for compound commands. Claude Code does not honor a hook `ask` for a piped or chained command (e.g. `git push --force-with-lease 2>&1 | tail`) whose segments each match an allow rule — it auto-approves the pipeline before the prompt surfaces, so the confirm is skipped. A `deny`, by contrast, is honored through a pipe. So that an `ask`-tier command isn't silently bypassed when piped, ClaudeWatch escalates an `ask` to a `deny` whenever the command is compound, with a message to re-run the guarded command on its own to get the prompt. Bare commands prompt normally; the escalation only changes the piped/chained form.

To keep agents out of that escalation in the first place, a `SessionStart` hook (`hooks/emit-rules.mjs`) injects a short ambient note advising that consequential steps be run as their own Bash call rather than chained. The content lives in `rules/*.md`; the escalation is the backstop, the note is the nudge that fires before it.

`watch-aws` leans on this. Unlike the interpreter sets — which stay silent on most commands and only block destructive variants — it *asks* on most `aws` commands and stays silent only on read-only ops (`get-`/`list-`/`describe-`/`head-`, `s3 ls`). `Bash(aws *)` is what makes those reads frictionless; without it they still hit Claude Code's default prompt. Mutations still prompt and destructive ops (`delete-`, `terminate-`, `s3 rm`, …) are still blocked, because the hook's decision wins over the allow rule.

### Discovering what to allow (`/ClaudeWatch:learn`)

Deciding *which* patterns to add to the allowlist is itself the chore. The engine appends each decision to a JSONL log by default, at `~/.claude/claudewatch/decisions.jsonl` — no setup needed. To log elsewhere, point `CLAUDEWATCH_LOG` at a path; to opt out, set it to `off` (which also disables `/ClaudeWatch:learn`, since it has nothing to read without the log):

```jsonc
// settings.json — the ClaudeWatch hook's env. Optional: override the default
// path, or set "off" to disable logging (and with it, /ClaudeWatch:learn).
{ "env": { "CLAUDEWATCH_LOG": "~/.claude/claudewatch/decisions.jsonl" } }
```

For a `Bash` decision the log records the command *shape* — the program plus its leading subcommand tokens (`git push`, `aws s3 cp`), stopping at the first flag, path, or value — rather than the full command, which keeps inline secrets (credentials in flags, URLs, or `VAR=value` prefixes) out of the plaintext log. The shape is what `/ClaudeWatch:learn` groups by, so nothing is lost for the workflow. The log file and its directory are owner-only (`0600`/`0700`).

Then `/ClaudeWatch:learn` aggregates the log into a batch proposal: frequently-allowed commands that aren't in your allowlist yet (promote them), ask rules you keep approving (add an `except`), and blocks that may be in your way. `scripts/analyze.mjs` does the read-only analysis; the skill drives the per-item approval. Because it works from the hook's own decisions rather than scanning transcripts heuristically, it distinguishes allowed / asked / blocked instead of guessing what looks read-only. You vet a window's worth of prompts once instead of one at a time. The proposal leads with the window it covers (records, sessions, span) so you can weigh it, and once you've applied changes the skill offers to reset the log (`scripts/reset.mjs`, archives by default) so the next pass measures from the new baseline rather than re-surfacing what you just handled.

## The `\n#` gate (and how to work around it)

Claude Code's built-in Bash input analyzer flags `\n#` (a newline followed by `#`) inside a quoted argument as potentially hiding arguments from path validation. The gate fires **before** any plugin hook runs, so ClaudeWatch never gets a chance to auto-approve. Agents that habitually write multi-line `python3 -c "..."` or `node -e "..."` scripts with embedded `#` comments will get a permission prompt every single invocation, regardless of the allowlist above.

The workaround is to author the script as a file and execute the file:

```bash
# instead of: python3 -c "import shutil  # tidy
# shutil.rmtree('./build')"
# write to a tmp file and run it:
TMP=$(mktemp /tmp/probe.XXXXXX.py)
# ...write the script to $TMP via your editor's Write tool...
python3 "$TMP"
```

Coverage is preserved: ClaudeWatch's `Write` and `Edit` hooks run the same `target: file-content` regex set that `target: bash` rules would have run on the inline command. A `Write` of `/tmp/probe.aB3xKp.py` containing `shutil.rmtree("/etc")` still gets blocked — see `watch-python.yml` for the dual `bash` / `file-content` rule pattern.

## Installation

```bash
claude plugin marketplace add chris-peterson/claude-marketplace
claude plugin install ClaudeWatch@chris-peterson
```

The engine (`scripts/watchdog.mjs`) and the `/ClaudeWatch:learn` tooling
(`scripts/analyze.mjs`, `scripts/reset.mjs`) run on Node, which ships with
Claude Code — there is nothing extra to install, and the hooks run natively on
every platform Claude Code supports. Python is needed only for dev/release-time
tooling (`scripts/gen-plugin-json.py`, `build/gen-rules-doc.py`) and the test
suite's assertion helpers, never on a user's machine.

## Updating

Third-party Claude Code marketplaces have auto-update **off by default**. Either:

- **Enable auto-update once** via `/plugin` → Marketplaces → `chris-peterson` → Enable auto-update. Future releases install on the next session start.
- **Or update manually** with `claude plugin update ClaudeWatch@chris-peterson`.

See [`CHANGELOG.md`](CHANGELOG.md) for release notes.

## Documentation

See the [docs site](https://chris-peterson.github.io/ClaudeWatch/) for usage, configuration, and the full [rules](https://chris-peterson.github.io/ClaudeWatch/#/rules) reference. The YAML rule format is documented for rule authors in [`SCHEMA.md`](SCHEMA.md).

In-session, run `/ClaudeWatch:help` for an overview or `/ClaudeWatch:rules` to view and edit rules interactively.

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
