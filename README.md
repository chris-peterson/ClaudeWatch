# ClaudeWatch

**ClaudeWatch:** agents move fast; watch them closely.

![Claude Code](https://img.shields.io/badge/Claude%20Code-%23D97757.svg?logo=claudecode&logoColor=white)
![GitHub top language](https://img.shields.io/github/languages/top/chris-peterson/ClaudeWatch)
![GitHub Release](https://img.shields.io/github/v/release/chris-peterson/ClaudeWatch?sort=semver&display_name=release&logo=github&label=latest)

Screens every shell command and every file Claude writes, before either lands. Blocks the dangerous, asks on anything that changes state.

Claude Code's built-in permission system uses naive string matching that [fails for compound commands, heredocs, and flag reordering](https://github.com/anthropics/claude-code/issues/30519). `ClaudeWatch` solves this with Python regex rules matched anywhere in the command string (or in the body of a script being written/edited) via `re.search()`.

## Rule Sets

The plugin ships these rule sets, each a standalone YAML file auto-discovered by the `watchdog` engine:

| Rule set | File | What it guards |
| --- | --- | --- |
| **watch-aws** | `watches/watch-aws.yml` | `aws … delete-`/`remove-`/`deregister-`/`terminate-`/`purge-`/`reset-`/`revoke-` ops, `release-address`, `s3 rm`/`s3 rb` (block); any other `aws` mutating operation (ask). Read-only `get-`/`list-`/`describe-`/`head-` ops and `s3 ls` are allowed. Matches through interspersed global flags (`aws --profile prod ec2 …`) |
| **watch-bash** | `watches/watch-bash.yml` | `rm -rf /`, `curl \| sh`, `dd of=/dev/sd*`, `mkfs /dev/*`, `shred` (block); `rm -rf` (skipped when the script deletes a cache or tmp path anywhere), `chmod 777`, `chown -R`, shell `eval` of dynamic strings (ask). Applies to `.sh`/`.bash`/`.zsh` file content authored via Write/Edit (bash-target rules for the same primitives live in watch-files) |
| **watch-dotnet** | `watches/watch-dotnet.yml` | .NET decompilers (`ilspycmd`, `ildasm`, `dotpeek`, `dnspy[ex]`, `justdecompile`), unzip/tar of `.nupkg`, curl/wget of `.nupkg`, and `nuget install` (ask). Nudges toward SourceLink instead of decompiling NuGet packages |
| **watch-exec** | `watches/watch-exec.yml` | Running code that can't be read before it runs (block): a download run through `$(curl …)` or `<(curl …)`, piped to an interpreter (`python`, `perl`, `node`, `ruby`, …), a `base64 -d` or `xxd -r` payload piped to a shell, and shells attached to a network connection (`nc -e`, `nc -l \| sh`, `socat … exec:`, `/dev/tcp/`). An interpreter given its own code (`python3 -m json.tool`, `perl -ne`) reads the download as data and is allowed. `curl \| sh` itself is in watch-installs |
| **watch-files** | `watches/watch-files.yml` | rm -rf /, chmod 777, shred, mv /dev/null, raw disk writes (`dd of=/dev/…`, `mkfs /dev/…`, `> /dev/sda`, `diskutil erase…`) (block); rm -rf, recursive chmod/chown (ask). Recursive `rm` is allowed when each target is inside the working directory or the project root, names a regenerable tool directory, or sits under a scratch root (`/tmp`, `/var/tmp`, their macOS `/private` forms, `~/.cache`); a delete with any other target gets an `ask`. The exemption reads only a bare `rm`: one inside a `bash -c` or `eval` script asks whatever its target, and one chained with another command is denied |
| **watch-git** | `watches/watch-git.yml` | Force push, `gc --prune=now`/`prune`, `filter-branch`/`filter-repo`, and other no-recovery git ops (block); commit, push, push --delete, reset --hard, branch -D, force-with-lease, and other recoverable mutating ops (ask). Stage-only ops (add, rm, non-hard reset) and the read-only stash list/show are allowed |
| **watch-host** | `watches/watch-host.yml` | `shutdown`, `reboot`, `halt`, `poweroff`, `systemctl poweroff\|reboot`, `crontab -r`, and fork bombs (block). Matches the power commands run as a command, not the word in an argument |
| **watch-installs** | `watches/watch-installs.yml` | curl\|sh, global installs, system package changes via brew (install, upgrade, uninstall, reinstall), choco (install, upgrade, uninstall), and apt install (block); npm install, yarn add, pip install, and other dependency changes (ask) |
| **watch-node** | `watches/watch-node.yml` | `fs.rmSync` at root/$HOME, `child_process.exec("rm -rf /")`, `new Function(...)` (block); `fs.unlink`, `fs.rm({recursive:true})`, `exec`/`execSync`, `vm.runIn*Context`, `eval` (ask). Applies to both `node -e`/`bun -e`/`deno`/`tsx` bash invocations and `.js`/`.mjs`/`.cjs`/`.ts`/`.mts`/`.cts` file content authored via Write/Edit |
| **watch-kill** | `watches/watch-kill.yml` | `pkill` and `killall` (ask), which kill every process matching a name or pattern rather than one process by id. Matches them run as a command, not the word in an argument (`grep pkill notes.md`) |
| **watch-publish** | `watches/watch-publish.yml` | `npm`/`pnpm`/`yarn unpublish` and `gem yank` (block); `npm`/`pnpm`/`yarn publish` (ask), skipping `--dry-run` |
| **watch-pwsh** | `watches/watch-pwsh.yml` | Format-Volume, Restart-Computer, IWR \| iex (block); Remove-Item -Recurse -Force, Stop-Process -Force, Out-File to sensitive paths (ask). Applies to both `pwsh -Command "..."` bash invocations and `.ps1`/`.psm1`/`.psd1` file content authored via Write/Edit |
| **watch-self** | `watches/watch-self.yml` | Every way the agent can loosen ClaudeWatch (block): writes under `~/.claude/claudewatch/` by shell or Write/Edit, `overrides.py set … ask\|off` and `reset`, `unattended.py off`, disabling or uninstalling the plugin, and settings that disable it or every hook. See [Self-protection](#self-protection) |
| **watch-su** | `watches/watch-su.yml` | `sudo` and `su` (block): running as root or as another user. A cached sudo timestamp or a `NOPASSWD` entry lets `sudo` run with no password prompt, so nothing else stands between the agent and root. Matches them run as a command, not the word in an argument (`grep sudo scripts/`) |
| **watch-python** | `watches/watch-python.yml` | shutil.rmtree at root/$HOME, pickle.loads, `__import__('os').system`, subprocess shell=True with destructive payload (block); eval, exec, os.system, os.remove, generic shell=True (ask). Applies to both `python3 -c "..."` bash invocations and `.py` file content authored via Write/Edit |
| **watch-remote** | `watches/watch-remote.yml` | `gh`/`glab repo delete`, `terraform`/`tofu destroy` (and `apply -destroy`), `pulumi destroy`/`down`, and `kubectl delete` of a namespace or with `--all` (block). Plans, previews, and single-resource deletes are allowed |
| **watch-ruby** | `watches/watch-ruby.yml` | `FileUtils.rm_rf` at root/$HOME, `Marshal.load`, `YAML.load` on input (block); `FileUtils.rm_rf`, `File.delete`, `system`/`exec`, backtick-with-interpolation, `eval`, `instance_eval`/`class_eval`/`module_eval` (ask). Applies to both `ruby -e` bash invocations and `.rb` file content authored via Write/Edit |
| **watch-secrets** | `watches/watch-secrets.yml` | Reading SSH keys or cloud credentials (AWS SSO/CLI caches included) with `cat`, `tac`, `xxd` and the other readers, or a bare `<` redirect; echo secrets (block); reading dotfiles, .env files, PEM/key files, secret-named files; env/printenv (ask). The dotfile ask skips Claude Code's skill and plugin caches under `~/.claude` |

Each rule set has an optional `filter` regex that short-circuits bash commands outside its domain. Rule sets targeting script bodies declare `extensions` to gate which `Write`/`Edit` payloads they evaluate. To add a new rule set, drop a YAML file in `watches/`.

### Changing how the rules apply to you (`/ClaudeWatch:rules`)

The shipped rule sets live in the plugin's install folder, which every upgrade replaces, so don't edit them there. `/ClaudeWatch:rules` keeps your changes in `~/.claude/claudewatch/overrides.yml` instead:

```yaml
watch-dotnet: off          # turn a whole rule set off
watch-git:
  git commit: block        # ask -> block
  git push --force: ask    # block -> ask
  git stash: off           # turn one rule off
```

An override moves a shipped rule between `block` and `ask` or turns it `off`; it can't add a rule or a pattern. A rule moved from ask to block keeps its exemptions, so `rm -rf` moved to block still lets in-tree and scratch deletes through. An override naming a rule an upgrade renamed or removed is ignored, and the next session start tells you about it. A file the engine can't parse denies every screened call until it's fixed, so a block you added can't silently disappear.

Each session start writes a `session_start` record to the decision log listing every difference from the shipped rules (and the plugin version), so how far your rules have drifted is on the record.

### Self-protection

A prompt-injected agent's shortest path past every rule is to turn ClaudeWatch off, so `watch-self` blocks the agent from loosening it: writing or deleting anything under `~/.claude/claudewatch/`, running `overrides.py` to move a rule to `ask` or `off` or to reset, ending unattended mode, disabling or uninstalling the plugin, and writing a settings file that disables it or every hook. The agent can still tighten (`overrides.py set … block`). When `/ClaudeWatch:rules` or `/ClaudeWatch:learn` proposes a loosening change, it prints the command for you to type with a `!` prefix, which runs it in the shell without passing through ClaudeWatch. This guards against an agent being steered into it, not against you: anything run outside the session, or a command that reaches the files some other way, is out of its reach.

## How decisions meet Claude Code's permissions

ClaudeWatch only ever **adds** scrutiny. Its decisions are `ask` and `deny`; when no rule matches it stays silent, and the call goes through Claude Code's normal permission flow (your allow rules, the permission mode, its own prompts) as if the hook weren't there. A hook decision outranks an `allow` rule, so ClaudeWatch's `ask` and `deny` fire regardless of your allow list.

The `Monitor` tool runs its command in the same shell as `Bash`, so ClaudeWatch screens it on the same terms and its matcher is `Bash|Monitor`.

One nuance for compound commands. A `deny` is honored in every permission mode; an `ask` is not (see [What an `ask` actually does](#what-an-ask-actually-does)). Chaining is where that costs most: the host's allow list can approve a pipeline segment-by-segment and auto-run it before any prompt surfaces, so `git push --force-with-lease 2>&1 | tail` can slip through even in a mode that would prompt on the bare command. ClaudeWatch therefore escalates an `ask` to a `deny` whenever the command is compound, with a message to re-run the guarded command on its own. A bare subshell, `(git push)`, counts as compound on the same grounds: Claude Code treats a command inside one the way it treats one inside a pipeline. A command left malformed by a dangling `&&` or `||` is the one chained form the host never auto-approves: it requires approval whatever the allow rules say, and ClaudeWatch's escalation applies to it on the same terms as any other compound. A `Monitor` command escalates on the same terms, since it runs unattended and repeats on a single approval: run the guarded step as its own `Bash` call rather than folding it into a watch loop.

To keep agents out of that escalation in the first place, a `SessionStart` hook (`hooks/emit-rules.sh`) injects a short ambient note advising that consequential steps be run as their own Bash call rather than chained. The content lives in `rules/*.md`; the escalation is the backstop, the note is the nudge that fires before it.

`watch-aws` takes the opposite posture to the interpreter sets. Those stay silent on most commands and only block destructive variants; `watch-aws` *asks* on most `aws` commands, blocks destructive ops (`delete-`, `terminate-`, `s3 rm`, …), and stays silent only on read-only ops (`get-`/`list-`/`describe-`/`head-`, `s3 ls`), which then get whatever Claude Code's permissions give them. Whether its `ask` prompts depends on the session (see [What an `ask` actually does](#what-an-ask-actually-does)).

### What an `ask` actually does

An `ask` is a request for confirmation, not a guarantee of one. Whether it reaches you is decided by how the session was launched and configured, and the hook has no way to tell:

| Session | What happens to an `ask` |
| --- | --- |
| Interactive, `default` / `plan` / `acceptEdits` | prompts, unless `permissions.denyInsteadOfPrompting` is on: then it is **denied** and the turn continues (Claude Code 2.1.319; applies to subagents and teammates too) |
| Interactive, `auto` | **runs unprompted** where the auto-mode server check is reachable: the mode clears the call before the hook's `ask` has a prompt surface ([claude-code#89561](https://github.com/anthropics/claude-code/issues/89561)). With telemetry or feature flags off, including behind an LLM gateway, Claude Code 2.1.319 asks about or denies calls the server can't check, unless `CLAUDE_CODE_AUTO_MODE_SERVER=0` keeps the built-in classifier |
| Interactive, no permission mode configured | as `auto`: the session starts there ([which mode a session starts in](https://code.claude.com/docs/en/permission-modes#which-mode-a-session-starts-in)) |
| Headless (`--print`) | **denied**: nobody can answer, so the call fails closed |

`deny` is honored in every case. The `auto` + telemetry-off row is what the 2.1.319 changelog states; `tests/probe-host-ask-behavior.sh` grades headless runs only. The practical consequences:

- **Set `permissions.defaultMode`, and leave `permissions.denyInsteadOfPrompting` off, if you want the `ask` tier to prompt.** In `~/.claude/settings.json` (or a project's `.claude/settings.json`), add the key to the `permissions` object:

  ```jsonc
  "permissions": {
    "defaultMode": "default"
  }
  ```

  `default` is the prompting mode, which Claude Code's UI labels "Manual" (`"manual"` is accepted too).
- **Put anything unrecoverable in the block tier.** A rule that guards something no reflog can undo should not depend on a prompt that may never appear.
- **A failed command in a headless run, or in any session with `denyInsteadOfPrompting` on, may be an unanswerable `ask`, not a block.** Read the message before concluding a rule stopped you.
- **`/ClaudeWatch:learn` cannot tell a reviewed run from an unreviewed one.** `permission_mode` reads `auto` whether or not a prompt was shown, and `--permission-prompts none` and `denyInsteadOfPrompting` set no field of their own, so an `ask` record is evidence the engine asked, never evidence a person answered.

### Tuning the rules (`/ClaudeWatch:learn`)

Deciding which rules prompt too often, and which blocks are in the way, is easier from history than from memory. The engine appends each decision to a JSONL log by default, at `~/.claude/claudewatch/decisions.jsonl`, with no setup needed. To log elsewhere, point `CLAUDEWATCH_LOG` at a path; to opt out, set it to `off` (which also disables `/ClaudeWatch:learn`, since it has nothing to read without the log):

```jsonc
// settings.json: the ClaudeWatch hook's env. Optional: override the default
// path, or set "off" to disable logging (and with it, /ClaudeWatch:learn).
{ "env": { "CLAUDEWATCH_LOG": "~/.claude/claudewatch/decisions.jsonl" } }
```

For a `Bash` or `Monitor` decision the log records the command *shape* rather than the full command: the program plus its leading subcommand tokens (`git push`, `aws s3 cp`), stopping at the first flag, path, or value. That keeps inline secrets (credentials in flags, URLs, or `VAR=value` prefixes) out of the plaintext log. The shape is what `/ClaudeWatch:learn` groups by, so nothing is lost for the workflow. The log file and its directory are owner-only (`0600`/`0700`).

Then `/ClaudeWatch:learn` aggregates the log into a batch proposal: ask rules you keep hitting (move to block, or turn off) and blocks that may be in your way (move to ask, or turn off). `scripts/analyze-decisions.py` does the read-only analysis; the skill drives the per-item approval and writes each approved change to your overrides file, the same one `/ClaudeWatch:rules` edits. The proposal leads with the window it covers (records, sessions, span) so you can weigh it, and once you've applied changes the skill offers to reset the log (`scripts/reset-decisions.py`, archives by default) so the next pass measures from the new baseline rather than re-surfacing what you just handled.

### Stepping away (`/ClaudeWatch:unattended`)

Type `/ClaudeWatch:unattended` (or say you're stepping away, and the agent invokes it) when you hand a session work and leave. The skill has the agent decide, log each call in a `NOTES.md`, and keep going instead of waiting on questions, then end with a review map of what it did, what it left prepared, and what it couldn't verify.

It also marks the session so nothing waits on you:

- ClaudeWatch's `ask` tier becomes a block, in every permission mode, `auto` included. An `ask` nobody can answer is either a stall or, in `auto`, a command that runs unconfirmed; neither is what the rule was for.
- A Claude Code permission prompt is denied at once, with a message telling the agent to take another route or leave the step prepared.
- A question to you (`AskUserQuestion`) is denied before it shows, so the agent decides and logs the call instead.

Both of those hooks fail closed: if one can't run (no `python3`, a crash, a timeout), the prompt or question is denied rather than left waiting. That holds in attended sessions too, so a broken hook shows up as denied prompts until it's fixed.

The exception is the local git work an unattended run needs to segment what it does: a bare `git add`, `git commit` (not `--amend`), `git switch` (not `-f` or `--discard-changes`), or `git checkout -b`. ClaudeWatch stays silent on those and approves their permission prompt, and writes an `ALLOW` line for each one to the session's unattended log (plus an `unattended_allow` field in `decisions.jsonl`), so every one is visible on return. Push and everything else stays denied.

The first thing you type turns the mark off. `python3 scripts/unattended.py status` (from a session, with `CLAUDE_CODE_SESSION_ID` set) reports the mark and how many calls it denied and allowed. The marker lives in `~/.claude/claudewatch/unattended/`.

`permissions.denyInsteadOfPrompting` (Claude Code 2.1.319) is the always-on version of the second effect. It is a setting, so it reaches every session that reads the settings file and does nothing about an `ask` that `auto` runs unprompted; the skill's mark is per session and covers both.

## The `\n#` gate (and how to work around it)

Claude Code's built-in Bash input analyzer flags `\n#` (a newline followed by `#`) inside a quoted argument as potentially hiding arguments from path validation. The gate fires **before** any plugin hook runs, so no hook (ClaudeWatch included) and no allow rule can clear it. Agents that habitually write multi-line `python3 -c "..."` or `node -e "..."` scripts with embedded `#` comments will get a permission prompt every single invocation, regardless of your allow rules.

The workaround is to author the script as a file and execute the file:

```bash
# instead of: python3 -c "import shutil  # tidy
# shutil.rmtree('./build')"
# write to a tmp file and run it:
TMP=$(mktemp /tmp/probe.XXXXXX.py)
# ...write the script to $TMP via your editor's Write tool...
python3 "$TMP"
```

Coverage is preserved: ClaudeWatch's `Write` and `Edit` hooks run the same `target: file-content` regex set that `target: bash` rules would have run on the inline command. A `Write` of `/tmp/probe.aB3xKp.py` containing `shutil.rmtree("/etc")` still gets blocked. See `watch-python.yml` for the dual `bash` / `file-content` rule pattern.

## Installation

Requirements: `python3` on PATH, and on Windows, Git for Windows. On Windows, `python3` has to resolve inside Git Bash to a real interpreter rather than the Microsoft Store alias; `python3 --version` run in Git Bash should print a version. The hooks set no `shell`, and Claude Code 2.1.299 and later block a guarded call when a hook with no `shell` can't run. On Windows without Git for Windows, that means every Bash, Monitor, Write, and Edit call is refused. Both guard hooks also declare `onFailure: block`, so on Claude Code 2.1.295 and later a `python3` that is missing or isn't a working interpreter refuses those same calls on any platform.

```bash
claude plugin marketplace add chris-peterson/claude-marketplace
claude plugin install ClaudeWatch@chris-peterson
```

## Updating

Third-party Claude Code marketplaces have auto-update **off by default**. Either:

- **Enable auto-update once** via `/plugin` → Marketplaces → `chris-peterson` → Enable auto-update. Future releases install on the next session start.
- **Or update manually** with `claude plugin update ClaudeWatch@chris-peterson`.

See [`CHANGELOG.md`](CHANGELOG.md) for release notes.

## Documentation

See the [docs site](https://chris-peterson.github.io/ClaudeWatch/) for usage, configuration, and the full [rules](https://chris-peterson.github.io/ClaudeWatch/#/rules) reference. The YAML rule format is documented for rule authors in [`SCHEMA.md`](SCHEMA.md).

In-session, run `/ClaudeWatch:rules` to view the rules and change how they apply to you, or `/ClaudeWatch:learn` to tune them from your decision log.

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
