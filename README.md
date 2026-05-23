# <img src="docs/favicon.svg" alt="ClaudeWatch" width="64" height="64"> ClaudeWatch

A Claude Code plugin that enforces command and script safety rules via a `PreToolUse` hook on `Bash`, `Write`, and `Edit`.

Claude Code's built-in permission system uses naive string matching that [fails for compound commands, heredocs, and flag reordering](https://github.com/anthropics/claude-code/issues/30519). `ClaudeWatch` solves this with Python regex rules matched anywhere in the command string (or in the body of a script being written/edited) via `re.search()`.

## Rule Sets

The plugin ships these rule sets, each a standalone YAML file auto-discovered by the `watchdog` engine:

| Rule set | File | What it guards |
| --- | --- | --- |
| **watch-bash** | `rules/watch-bash.yml` | `rm -rf /`, `curl \| sh`, `dd of=/dev/sd*`, `mkfs /dev/*`, `shred` (block); `rm -rf` outside cache/tmp paths, `chmod 777`, `chown -R`, shell `eval` of dynamic strings (ask). Applies to `.sh`/`.bash`/`.zsh` file content authored via Write/Edit (bash-target rules for the same primitives live in watch-files) |
| **watch-dotnet** | `rules/watch-dotnet.yml` | .NET decompilers (`ilspycmd`, `ildasm`, `dotpeek`, `dnspy[ex]`, `justdecompile`), unzip/tar of `.nupkg`, curl/wget of `.nupkg`, and `nuget install` (ask). Nudges toward SourceLink instead of decompiling NuGet packages |
| **watch-files** | `rules/watch-files.yml` | rm -rf /, chmod 777, shred, mv /dev/null (block); rm -rf, recursive chmod/chown (ask) |
| **watch-git** | `rules/watch-git.yml` | Force push, reset --hard, branch -D, and other destructive git ops (block); add, commit, push, and other mutating ops (ask) |
| **watch-installs** | `rules/watch-installs.yml` | curl\|sh, global installs, sudo pip/apt (block); npm install, yarn add, pip install, and other dependency changes (ask) |
| **watch-node** | `rules/watch-node.yml` | `fs.rmSync` at root/$HOME, `child_process.exec("rm -rf /")`, `new Function(...)` (block); `fs.unlink`, `fs.rm({recursive:true})`, `exec`/`execSync`, `vm.runIn*Context`, `eval` (ask). Applies to both `node -e`/`bun -e`/`deno`/`tsx` bash invocations and `.js`/`.mjs`/`.cjs`/`.ts`/`.mts`/`.cts` file content authored via Write/Edit |
| **watch-pwsh** | `rules/watch-pwsh.yml` | Format-Volume, Restart-Computer, IWR \| iex (block); Remove-Item -Recurse -Force, Stop-Process -Force, Out-File to sensitive paths (ask). Applies to both `pwsh -Command "..."` bash invocations and `.ps1`/`.psm1`/`.psd1` file content authored via Write/Edit |
| **watch-python** | `rules/watch-python.yml` | shutil.rmtree at root/$HOME, pickle.loads, `__import__('os').system`, subprocess shell=True with destructive payload (block); eval, exec, os.system, os.remove, generic shell=True (ask). Applies to both `python3 -c "..."` bash invocations and `.py` file content authored via Write/Edit |
| **watch-ruby** | `rules/watch-ruby.yml` | `FileUtils.rm_rf` at root/$HOME, `Marshal.load`, `YAML.load` on input (block); `FileUtils.rm_rf`, `File.delete`, `system`/`exec`, backtick-with-interpolation, `eval`, `instance_eval`/`class_eval`/`module_eval` (ask). Applies to both `ruby -e` bash invocations and `.rb` file content authored via Write/Edit |
| **watch-secrets** | `rules/watch-secrets.yml` | cat SSH keys, cloud credentials, echo secrets (block); cat dotfiles, .env files, env/printenv (ask) |

Each rule set has an optional `filter` regex that short-circuits bash commands outside its domain. Rule sets targeting script bodies declare `extensions` to gate which `Write`/`Edit` payloads they evaluate. To add a new rule set, drop a YAML file in `rules/`. To disable one, rename it to `*.yml.disabled`.

## Pairing with Bash permissions

Agents routinely generate one-off scripts to complete tasks — both inline (`python3 -c "..."`, `pwsh -Command "..."`) and as authored files (`Write` of a `.py` or `.ps1`). Reviewing every such invocation through a permission prompt is impractical: the script body is opaque in the prompt, and clicking "allow" doesn't reflect real consent.

ClaudeWatch's regex matching reaches anywhere in the command string and into the body of `Write`/`Edit` payloads, which covers cases Claude Code's built-in `startsWith` rules can't see. That makes it safe to broaden your Bash allowlist for the interpreters agents reach for, and let ClaudeWatch be the safety net that blocks destructive variants (`shutil.rmtree` at filesystem roots, `Format-Volume`, `Invoke-WebRequest | iex`, etc.):

```jsonc
// .claude/settings.json
{
  "permissions": {
    "allow": [
      "Bash(python3 *)",
      "Bash(pwsh *)"
    ]
  }
}
```

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
claude plugin marketplace add https://github.com/chris-peterson/claude-marketplace
claude plugin install ClaudeWatch@chris-peterson
```

## Updating

Third-party Claude Code marketplaces have auto-update **off by default**. Either:

- **Enable auto-update once** via `/plugin` → Marketplaces → `chris-peterson` → Enable auto-update. Future releases install on the next session start.
- **Or update manually** with `claude plugin update ClaudeWatch@chris-peterson`.

See [`CHANGELOG.md`](CHANGELOG.md) for release notes.

## Documentation

See the [docs site](https://chris-peterson.github.io/ClaudeWatch/) for usage, configuration, and the full [default rules](https://chris-peterson.github.io/ClaudeWatch/#/rules) reference.

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
