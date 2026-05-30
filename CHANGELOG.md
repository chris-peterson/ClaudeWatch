# Changelog

## 0.8.0

### Features
- New `watch-aws` rule set guards AWS CLI operations by reversibility. Unlike the deny-list sets, it takes an allow-list posture: it asks on any mutating `aws <service> <operation>` and stays silent only on read-only commands (`get-`/`list-`/`describe-`/`head-` verbs and `s3 ls`). Irreversible operations are blocked outright — `delete-`/`remove-`/`deregister-`/`terminate-`/`purge-`/`reset-`/`revoke-` verbs, `ec2 release-address`, and the `s3 rm` / `s3 rb` high-level commands. Matching reaches through interspersed global flags (`aws --profile prod ec2 terminate-instances`), and the service token is anchored so a profile or region named like a verb (`--profile delete-prod`) doesn't trip a block.
- README's "Pairing with Bash permissions" section now covers `aws`: add `Bash(aws *)` to your Claude Code allowlist to make the allowed read-only commands frictionless. It's safe because a hook `ask`/`deny` decision takes precedence over a settings `allow` rule — mutating `aws` commands still prompt and destructive ones still block.

### Other
- A dev-time PostToolUse hook reminds contributors to update the three hand-maintained rule-set indexes (README table, SPEC `[SH-01]`, help-skill table) whenever a `rules/watch-*.yml` file changes — they previously drifted independently. This guards development of ClaudeWatch itself and is not part of the shipped plugin.
- `AGENTS.md` documents the deny-list vs allow-list posture choice (when to enumerate dangers vs use a catch-all `ask` + `except`) and expands the "new rule set" checklist to name all three indexes.
- `SPEC.md`: `watch-aws` recorded in `[SH-01]`; `[FUT-04]` added for the gap that `/ClaudeWatch:rules` edits don't survive plugin upgrades; `DOC-03` (Pages hosting) dropped; `DIST-01` reframed to manifest exposure with hosting out of scope.

## 0.7.1

### Fixes
- `watch-git` previously blocked `git reset --hard` and `git push --force-with-lease` outright. Both have legitimate uses — discarding uncommitted local work the user explicitly wants gone, and the safer-than-bare-force flag for rewriting a shared branch after rebase — that don't warrant an unrecoverable block. Both now ask instead, so the user still gets the safety prompt with the destructive-action context but can confirm and proceed.
- The block rule for force push now excludes `--force-with-lease` via a `(?!-)` negative lookahead (it still blocks plain `--force` and `-f`). The generic `git push` and `git reset` ask rules pick up matching negative lookaheads so the more specific ("rewrites remote history with stale-ref protection", "discards uncommitted changes with no recovery") messages aren't duplicated by the generic ones when both would match.

## 0.7.0

### Features
- Three new interpreter rule sets close the agent-script coverage gap that previously stopped at Python and PowerShell:
  - `watch-node` covers Node/JavaScript primitives across `node -e`/`bun -e`/`deno`/`tsx`/`ts-node` bash invocations and `.js`/`.mjs`/`.cjs`/`.ts`/`.mts`/`.cts` files. Blocks `fs.rmSync` at filesystem roots, `child_process` exec with `rm -rf /`, and `new Function(...)`. Asks on `fs.unlink`, `fs.rm({recursive:true})`, `exec`/`execSync`, `vm.runIn*Context`, and `eval`.
  - `watch-ruby` covers Ruby primitives across `ruby -e` and `.rb` files. Blocks `FileUtils.rm_rf` at roots, `Marshal.load`, and `YAML.load(...)`. Asks on `File.delete`, `system`/`exec` with string literals, backtick exec with interpolation, `eval`, and `instance_eval`/`class_eval`/`module_eval`.
  - `watch-bash` covers `.sh`/`.bash`/`.zsh` file content (bash-target coverage already lives in `watch-files`). Blocks `rm -rf /`, `curl|sh`, `dd of=/dev/sd*`, `mkfs /dev/...`, `shred`. Asks on `rm -rf` outside cache/tmp paths, `chmod 777`, `chown -R`, and shell `eval` of dynamic strings.
- README now documents the interaction with Claude Code's built-in `\n#` bash-input gate: that gate fires before any plugin hook and can't be auto-approved, so agents that write multi-line `python3 -c "..."` or `node -e "..."` scripts with embedded `#` comments will keep hitting permission prompts. The fix is to write the script to a tmp file (via `Write`) and execute the file — ClaudeWatch's `file-content` rules preserve coverage at the write site.
- The YAML parser now warns on unrecognized lines (to stderr) instead of silently dropping them. Typos like `refrence:` instead of `ref:` are surfaced so the rule author can fix them, rather than being baked into a rule that doesn't behave as intended.

### Other
- `SPEC.md` consolidates the shipped-rule-set requirements (formerly one `SH-XX` per rule set) under a single `SH-01` with a bulleted list, so future rule sets can be added without renumbering. Adds `RL-14` for the parser warning behavior.
- Tests added: `test-watch-bash.sh`, `test-watch-node.sh`, `test-watch-ruby.sh`. Engine tests now include an `unrecognized YAML field warns` case asserting the new parser warning.

## 0.6.0

### Features
- New `watch-dotnet` rule set nudges agents toward SourceLink when they reach for the "download .nupkg → decompile DLL" path. Asks (rather than blocks) on .NET decompilers (`ilspycmd`, `ildasm`, `dotpeek`, `dnspy`/`dnspyex`, `justdecompile`), on `.nupkg` extraction (`unzip`/`tar`) or download (`curl`/`wget`), and on ad-hoc `nuget install`. Decompiled output is approximate; SourceLink follows the package's PDB symbols to the real upstream commit — the rule's `ref` URL takes the user straight to the docs. Decompiler-name matching is case-insensitive so Windows-style executables aren't bypassed by capitalization.

### Other
- `/ClaudeWatch:help` overview now lists every shipped rule set (`watch-pwsh`, `watch-python`, `watch-dotnet` were missing from the table).
- `SPEC.md` adds `SH-10` covering the new rule set.

## 0.5.0

### Features
- ClaudeWatch now inspects file content sent through the `Write` and `Edit` tools, not just `Bash` commands. Destructive primitives hidden inside a script file (e.g. `Remove-Item -Recurse -Force /` in a `.ps1` that gets executed later via `pwsh ./cleanup.ps1`) are now caught at write time — clicking "approve" on an opaque script invocation is no longer the only line of defense. For `Edit`, the engine reconstructs the full post-edit file content before matching, so a small fragment that introduces a destructive call still trips the rule.
- New `watch-pwsh` rule set covers destructive PowerShell across both inline `pwsh -Command "..."` invocations and `.ps1` / `.psm1` / `.psd1` file contents. Block rules: `Format-Volume`, `Clear-Disk`, `Restart-Computer`, `Stop-Computer`, `Invoke-WebRequest | iex`, plus `Remove-Item -Recurse -Force` inside script files. Ask rules: inline `Remove-Item -Recurse -Force` (with `~/.cache/`, `/tmp/`, `/var/tmp/` excepted), other `Remove-Item` variants, `Stop-Process -Force`, and overwrites of sensitive paths like `/etc/`, `~/.ssh/`, `~/.aws/`.
- New `watch-python` rule set covers destructive Python across both inline `python3 -c "..."` invocations and `.py` file contents. Block rules: `shutil.rmtree` at filesystem roots (`/`, `~`, `$HOME`), `pickle.loads`, `__import__('os').system` / `popen`, and `subprocess` calls with `shell=True` plus a destructive payload. Ask rules: other `shutil.rmtree`, `os.remove` / `os.unlink`, `os.system`, generic `shell=True`, `eval(`, `exec(`.
- Rule-set YAML now supports two new backwards-compatible fields. Per-rule `target: bash | file-content` (default `bash`) selects which input the rule matches against — bash commands or written/edited file content. Per-rule-set `extensions: [.ext, ...]` (e.g. `['.ps1', '.psm1', '.psd1']`) gates file-content rules by file extension so the engine only evaluates Python rules against `.py` files, PowerShell rules against `.ps1` files, etc. Existing rule sets need no changes; they continue to behave as bash-only.
- Broad Bash allowlists like `Bash(python3 *)` or `Bash(pwsh *)` are now viable in your Claude Code permissions: with content-level matching in place, ClaudeWatch catches the destructive variants regardless of how the script reaches the shell, so blanket `Bash(...)` permission no longer means blanket trust of the script's contents.

### Other
- `SPEC.md` and `docs/schema.md` document the new requirements (`EN-12`/`EN-13` for Write/Edit handling, `RL-10..13` for `target`, `RS-07`/`RS-08` for `extensions`, `HK-01` updated for the `Write|Edit` matcher, `SH-08`/`SH-09` for the two new shipped rule sets) and the user-facing YAML schema for `target` and `extensions`.
- Engine and rule-set test coverage extended to exercise target dispatch (bash-only, file-only, default), extension gating with case-insensitive matching, Edit content reconstruction with and without an on-disk file (including `replace_all`), invalid-target diagnostics, and silent handling of unsupported tool names.

## 0.4.2

### Fixes
- The watchdog hook now logs malformed-JSON input to stderr instead of failing silently, making bad-payload incidents diagnosable.

### Other
- Plugin description in `plugin.json` no longer says "enforce" (typo) or "claude-watches" (wrong tool name); now reads "enforces command safety rules via 'claude-watchdog'".
- Added internal contributor docs — `SPEC.md` (formal contract), `STATUS.md` (spec-coverage audit), and `AGENTS.md` (build philosophy) — so future agent sessions and human contributors have a reading order. `CLAUDE.md` now imports `AGENTS.md`.

## 0.4.1

### Fixes
- The watch-secrets `env` / `printenv` ask-rule no longer triggers on hyphenated tokens like `data-env` or `printenv-extra` appearing in comments or filenames. The previous regex used `\b...\b` boundaries, which treat hyphens as word separators; the rule now requires shell command boundaries (start of line, whitespace, `;`, `&&`, `|`, backtick, parens) on both sides.

## 0.4.0

### Other
- Adopted the `SessionStart` cli-freshness hook pattern from the chris-peterson plugin namespace for symmetry. ClaudeWatch is a pure-hook plugin with no `install-cli` wrapper to drift, so the handler is intentionally empty (one comment, `exit 0`); it exists as a placeholder for future plugin-update self-checks specific to a hook plugin (e.g., verifying `watchdog.py` emits the expected `permissionDecision` schema — the kind of regression that shipped silently in 0.2.0).

## 0.3.0

### Other
- Established `plugin.json` as the single source of truth for the version. The project is moving to a main-only release model with no version tags; existing tags (`1.0.0`, `0.0.2`) will be deleted separately.
- Added an "Updating" section to the README documenting the auto-update path for end users.

## 0.2.1

### Fixes
- Ask-rules now actually prompt the user. Prior versions emitted the legacy hook output schema, which Claude Code silently treated as no-op for `ask` decisions — meaning every ask-rule (`git push`, `git commit`, `npm install`, etc.) was allowed through without confirmation. Updated to the current `hookSpecificOutput.permissionDecision` schema; both `deny` and `ask` decisions now route through it.
