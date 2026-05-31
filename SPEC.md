# ClaudeWatch — Specification (v1)

ClaudeWatch is a Claude Code plugin that enforces Bash command and script
safety via a `PreToolUse` hook. A generic engine evaluates regex rules loaded
from self-contained YAML rule sets and emits a single coalesced decision
(block / ask / allow) for each Bash, Write, or Edit invocation. Rules may
target the bash command string or the body of a script file being written or
edited, so destructive intent is caught both inline (`pwsh -Command "..."`)
and at the moment a script file is authored.

This spec captures the contract — what the system must do — independent of
how it's currently implemented. Mechanism notes (current file layout, parser
internals) live in §11.

Requirement IDs use `[XX-NN]`. Categories:

- **EN** — Engine (input, output, lifecycle)
- **RS** — Rule sets (file format, discovery)
- **RL** — Rules (block, ask, except)
- **OUT** — Output decisions
- **LOG** — Decision logging (opt-in side channel)
- **HK** — Hook wiring
- **EXT** — Extensibility
- **SK** — Skills (`/ClaudeWatch:help`, `/ClaudeWatch:rules`, `/ClaudeWatch:learn`)
- **DOC** — Documentation
- **DIST** — Distribution / install
- **SH** — Shipped rule sets
- **DEV** — Development workflow
- **FUT** — Deferred / future

Requirements use [EARS syntax](https://alistairmavin.com/ears) — Ubiquitous (no
keyword), State-Driven (`While`), Event-Driven (`When`), Optional (`Where`),
Unwanted (`If…then`).

---

## 1. Engine (EN)

**Core contract:** Given tool input on stdin, the engine deterministically
emits exactly one of `{deny, ask, no-output}` and exits 0. The engine handles
three tool inputs: `Bash` (matched against the bash command string), `Write`
(matched against the new file content), and `Edit` (matched against the full
post-edit file content).

- **[EN-01]** The engine shall read tool input from stdin as a single JSON object.
- **[EN-02]** When `tool_name` is not one of `"Bash"`, `"Write"`, `"Edit"`, the engine shall produce no output and exit 0.
- **[EN-03]** When the relevant input field for the tool is empty or absent, the engine shall produce no output and exit 0. The relevant field is `tool_input.command` for `Bash`, `tool_input.content` for `Write`, and `tool_input.new_string` (combined with `tool_input.file_path`) for `Edit`.
- **[EN-04]** If stdin is not valid JSON, then the engine shall produce no output and exit 0.
- **[EN-04a]** If stdin is not valid JSON, then the engine shall write the parse error to stderr before exiting so the failure is visible in transcripts.
- **[EN-05]** The engine shall accept a rules path as its first CLI argument.
- **[EN-05a]** Where the engine is invoked without a rules-path argument, it shall use the directory `../rules` relative to the engine script.
- **[EN-06]** When the rules path is a directory, the engine shall evaluate every `*.yml` file in that directory.
- **[EN-07]** When the rules path is a single file, the engine shall evaluate only that file.
- **[EN-08]** If the rules path does not exist, then the engine shall emit a `deny` decision with a "rules not found" reason that names the path.
- **[EN-09]** When the engine evaluates multiple rule files, it shall process them in a stable, sorted order.
- **[EN-10]** The engine's process exit code shall be `0` regardless of decision or error condition.
- **[EN-11]** The engine shall not require any third-party Python packages at runtime.
- **[EN-12]** When evaluating a `Write` input, the engine shall match rules against the value of `tool_input.content`.
- **[EN-13]** When evaluating an `Edit` input, the engine shall read the file at `tool_input.file_path`, apply the `old_string` → `new_string` substitution (all occurrences if `tool_input.replace_all` is true, otherwise the first occurrence), and match rules against the resulting full content. If the file cannot be read, the engine shall match against `tool_input.new_string` alone.

### Decision logging (LOG)

Logging is an opt-in side channel that records each decision for later review
(see [SK-13]–[SK-17]). It is separable from the decision: the engine's output
is identical whether or not logging is enabled.

- **[LOG-01]** Where the `CLAUDEWATCH_LOG` environment variable is set to a non-empty value, the engine shall append one JSON record per evaluated input to that path. The literal value `1` shall select the default path `~/.claude/claudewatch/decisions.jsonl`.
- **[LOG-02]** When `CLAUDEWATCH_LOG` is unset or empty, the engine shall write no log, and its decision and exit behavior shall be unchanged.
- **[LOG-03]** Each log record shall include the decision (`allow`/`ask`/`deny`), the matched rule reasons, a UTC timestamp, and the `session_id`, `cwd`, and active `permission_mode` from the hook input. For a `Bash` input the record shall include the command string; for a `Write`/`Edit` input it shall include the target file path rather than the file content.
- **[LOG-04]** Logging shall not influence the decision and shall not change the process exit code. If a log write fails, then the engine shall report the failure to stderr and otherwise continue, still emitting its decision.

## 2. Rule Sets (RS)

A rule set is a single YAML file declaring a named bundle of rules.

- **[RS-01]** Each rule set shall declare a top-level `name` field.
- **[RS-02]** Where a `filter` regex is declared, when it does not match the bash command, the engine shall skip all `target: bash` rules in that set. The `filter` shall not gate `target: file-content` rules.
- **[RS-03]** Each rule set shall declare a `rules` map containing optional `block` and `ask` lists.
- **[RS-04]** Where a rule set file is named `*.yml.disabled`, the engine shall not load it.
- **[RS-05]** If a rule set fails to load (parse error, file unreadable), then the engine shall emit a `deny` with a load-error reason and continue evaluating remaining rule sets.
- **[RS-06]** If a rule set's `filter` regex is invalid, then the engine shall emit a `deny` with the regex error and skip the rest of that set.
- **[RS-07]** Each rule set may declare an optional top-level `extensions` field as an inline list (e.g. `extensions: ['.ps1', '.psm1']`). The engine shall evaluate `target: file-content` rules in this set only when the `Write`/`Edit` target file's extension matches one of the listed values (case-insensitive).
- **[RS-08]** If a rule set has no `extensions` field, then the engine shall not evaluate its `target: file-content` rules for any `Write`/`Edit` input.

## 3. Rules (RL)

Rules are the matchable units within a rule set.

- **[RL-01]** Each rule shall declare `name`, `pattern`, and `reason`.
- **[RL-02]** Each rule may declare an optional `ref` URL.
- **[RL-03]** Rule patterns shall be Python regexes matched against the input string with `re.search()` semantics (matches anywhere; no implicit anchoring). The input string depends on the rule's `target`: the bash command for `target: bash`, the script body for `target: file-content`.
- **[RL-04]** If a rule's `pattern` is empty, then the engine shall emit a `deny` with a configuration-error reason naming the rule.
- **[RL-05]** If a rule's `pattern` is an invalid regex, then the engine shall emit a `deny` with the regex error and continue.
- **[RL-06]** Within a rule set, the engine shall evaluate `block` rules before `ask` rules.
- **[RL-07]** Where an `except` regex is declared on an `ask` rule, when both `pattern` and `except` match, the engine shall skip that rule (no ask emitted).
- **[RL-08]** If an `except` field appears on a `block` rule, then the engine shall log a warning to stderr and ignore the field; the block rule shall still fire on `pattern` match.
- **[RL-09]** If a rule's `except` regex is invalid, then the engine shall emit a `deny` with the regex error and continue.
- **[RL-10]** Each rule may declare an optional `target` field with value `bash` or `file-content`. If omitted, the rule defaults to `target: bash`.
- **[RL-11]** When evaluating a `Bash` input, the engine shall evaluate only `target: bash` rules.
- **[RL-12]** When evaluating a `Write` or `Edit` input, the engine shall evaluate only `target: file-content` rules whose containing rule set's `extensions` list matches the input's file extension.
- **[RL-13]** If a rule's `target` value is neither `bash` nor `file-content`, then the engine shall emit a `deny` with a configuration-error reason naming the rule.
- **[RL-14]** If a YAML line in a rule set does not match any recognized field at its indent level, then the engine shall log a warning to stderr naming the rule set, the rule (when applicable), and the unrecognized line; the engine shall continue processing the remaining lines. This surfaces typos like `refrence:` instead of `ref:` that would otherwise be silently dropped.

## 4. Output Decisions (OUT)

The engine emits at most one decision per invocation.

- **[OUT-01]** When emitting a decision, the engine shall write a single JSON object to stdout matching the Claude Code `hookSpecificOutput` schema with `hookEventName: "PreToolUse"` and `permissionDecision` set to `"deny"` or `"ask"`.
- **[OUT-02]** When emitting a decision, the engine shall format each violation as `<rule-set-name> — <reason>` (with ` — <ref>` appended when `ref` is present).
- **[OUT-03]** When any block rule matches in any rule set, the engine shall emit a single `deny` decision aggregating all block reasons, separated by newlines.
- **[OUT-04]** When no block rule matches and at least one ask rule matches in any rule set, the engine shall emit a single `ask` decision aggregating all ask reasons, separated by newlines.
- **[OUT-05]** When no rule matches, the engine shall produce no stdout output (allow-by-default).

## 5. Hook Wiring (HK)

- **[HK-01]** The plugin shall register `PreToolUse` hooks that invoke the engine against the plugin's rules directory for the `Bash`, `Write`, and `Edit` tools. Matchers may be combined via regex alternation (e.g. `matcher: "Write|Edit"`).
- **[HK-02]** The plugin shall register a `SessionStart` hook for plugin-update self-checks. (Currently a no-op placeholder — see [FUT-01].)
- **[HK-03]** The plugin shall declare its hooks in `hooks/hooks.json`.

## 6. Extensibility (EXT)

- **[EXT-01]** Where a new `*.yml` file is added to the rules directory, the engine shall auto-discover it on the next invocation without any configuration change to `hooks.json`.
- **[EXT-02]** Where a rule set is renamed from `*.yml` to `*.yml.disabled`, the engine shall stop loading it on the next invocation.
- **[EXT-03]** New rule sets shall not require code changes to the engine.

## 7. Skills (SK)

The plugin ships interactive Claude Code skills that surface and edit rules
without leaving the session.

### `/ClaudeWatch:help`

- **[SK-01]** Where the user invokes `/ClaudeWatch:help`, the skill shall display an overview covering: shipped rule sets, available commands, decision semantics, and documentation links.

### `/ClaudeWatch:rules`

- **[SK-02]** Where the user invokes `/ClaudeWatch:rules`, the skill shall list every enabled rule set with two tables (block, ask) using stable IDs of the form `<short-name>-block-NN` and `<short-name>-ask-NN` (zero-padded).
- **[SK-03]** When listing rule sets, the skill shall also list any disabled rule sets (`*.yml.disabled`).
- **[SK-04]** Where the user passes `--list`, the skill shall list rules and exit without entering the edit loop.
- **[SK-05]** When the user enters an edit command, the skill shall accept one operation per turn and loop until the user enters `done`. The supported operations are: `<id>:block` (move rule to block), `<id>:ask` (move rule to ask), `<id>:allow` (remove the rule), `add` (add a new rule), `disable <name>` (disable a rule set), `enable <name>` (re-enable a disabled rule set), and `new` (create a new rule set).
- **[SK-06]** Before writing edits, the skill shall scan for duplicate patterns, shadowing patterns, and cross-section conflicts (same pattern in both block and ask) and shall report any findings to the user.
- **[SK-07]** Before writing edits, the skill shall present a preview of the updated rule tables and shall require explicit confirmation (`yes` / `edit` / `abort`) from the user.
- **[SK-08]** When applying edits, the skill shall write only modified rule set files and shall preserve the standard YAML format.
- **[SK-09]** When the user issues `disable <name>`, the skill shall rename `rules/<name>.yml` to `rules/<name>.yml.disabled`.
- **[SK-10]** When the user issues `enable <name>`, the skill shall rename `rules/<name>.yml.disabled` to `rules/<name>.yml`.
- **[SK-11]** When the user issues `new`, the skill shall create a new `rules/watch-<name>.yml` (the name shall start with `watch-`) with the standard YAML format.
- **[SK-12]** After applying changes, the skill shall run `tests/test-watchdog.sh` and shall report any failures.

### `/ClaudeWatch:learn`

The learn skill aggregates the decision log ([LOG-01]–[LOG-04]) into a batch
of proposed permission changes, so the user vets accumulated prompts once
rather than per command.

- **[SK-13]** Where the user invokes `/ClaudeWatch:learn`, the skill shall analyze the decision log and present its proposals. If no log exists, the skill shall instruct the user how to enable `CLAUDEWATCH_LOG` and shall make no changes.
- **[SK-14]** The skill shall present three groups: **allow candidates** (frequently-allowed commands not covered by the current allow list), **ask candidates** (commands ClaudeWatch repeatedly asks about, with the matched rule), and a **deny summary** (blocked commands grouped by reason, informational).
- **[SK-15]** The skill shall accept an optional time window (e.g. `--since 1d`) and forward it to the analysis.
- **[SK-16]** Before writing any change, the skill shall present the exact edits and require explicit confirmation, and shall apply only the items the user approves.
- **[SK-17]** The skill shall apply approved allow-list additions to a `settings.json` whose scope (user or project) the user selects, shall route rule changes (`except` additions, demotions) through `/ClaudeWatch:rules`, and shall not modify deny-summary items automatically.

## 8. Documentation (DOC)

- **[DOC-01]** The plugin shall ship a Docsify documentation site under `docs/`.
- **[DOC-02]** `just docs` shall regenerate the rules-reference page from the YAML rule files.
- **[DOC-04]** The documentation shall include a YAML schema reference covering top-level fields and rule fields.

## 9. Distribution (DIST)

- **[DIST-01]** The plugin shall expose the metadata required for installation as a Claude Code plugin (name, version, description, repository, license) in its manifest. The mechanism by which the plugin is hosted or distributed (marketplace registration, install command) is out of scope.
- **[DIST-02]** The plugin shall declare a manifest at `.claude-plugin/plugin.json`.
- **[DIST-03]** The plugin shall be runnable from a working copy via `claude --plugin-dir .` (no install required for local testing).

## 10. Shipped Rule Sets (SH)

These are the rule sets the plugin ships out of the box. Each is
self-contained and removable by renaming its file to `*.yml.disabled`.

- **[SH-01]** The plugin shall ship the following rule sets:

  - **`watch-aws`** — AWS CLI operations classified by reversibility. **Block** rules shall cover irreversible operations: AWS operations whose verb begins with `delete-`, `remove-`, `deregister-`, `terminate-`, `purge-`, `reset-`, or `revoke-`; the EC2 `release-address` operation; and the `s3` high-level `rm` and `rb` subcommands. A single **ask** rule shall match any other `aws <service> <operation>`, with an `except` that allows read-only operations (`get-`/`list-`/`describe-`/`head-` verb prefixes and the `s3` high-level `ls` subcommand). Rules shall match through interspersed global flags (`-`-prefixed options before the service and between service and operation), including quoted values containing spaces, so that `aws --profile prod ec2 terminate-instances` is not silently bypassed.

  - **`watch-bash`** — destructive shell primitives in `.sh`/`.bash`/`.zsh` file content authored via `Write`/`Edit`. File-content only; bash-target coverage for the same primitives lives in `watch-files`. **Block** rules shall cover: `rm -rf /`, `rm -rf /*`, `curl|sh`/`wget|sh`, `dd of=/dev/sd*` (and `nvme`/`disk`/`hd`/`xvd`), `mkfs /dev/...`, and `shred`. **Ask** rules shall cover: recursive `rm -rf` (with `except` for `~/.cache/`, `/tmp/`, `/var/tmp/`, `$TMPDIR`), `chmod 777`, recursive `chown -R`, and shell `eval` of dynamic strings.

  - **`watch-dotnet`** — .NET decompilation and NuGet introspection. **Ask** rules nudge agents toward SourceLink rather than decompilation: .NET decompiler invocations (`ilspycmd`, `ildasm`, `dotpeek`, `dnspy`/`dnspyex`, `justdecompile`), `unzip`/`tar` of a `.nupkg` file, `curl`/`wget` of a `.nupkg` URL, and `nuget install`. Decompiler-name matching shall be case-insensitive so that Windows-style executables (`dnSpy.exe`, `ILDASM.exe`) are not bypassed. Each rule's `ref` shall point to SourceLink documentation.

  - **`watch-files`** — generic destructive filesystem operations. **Block** rules shall cover: `rm -rf /`, `rm -rf /*`, `chmod 777`, `mv … /dev/null`, and `shred`. **Ask** rules shall cover: recursive `rm -rf`, recursive `rm -r`, `mv` from a root-level path, `chmod`, and `chown`. Where a recursive-rm ask rule fires on a path under `~/.cache/`, `/tmp/`, or `/var/tmp/`, the rule shall be skipped via `except`.

  - **`watch-git`** — destructive git operations. **Block** rules shall cover: `git push --force` (excluding `--force-with-lease`), `git checkout .`, `git checkout -- <file>`, `git restore .`, `git clean -f`, `git branch -D`, `git stash drop`, `git stash clear`, and `git reflog expire/delete`. **Ask** rules shall cover: `git add`, `git rm`, `git rm --cached`, `git reset`, `git reset --hard`, `git commit`, `git stash`, `git push`, and `git push --force-with-lease`. Each rule shall match through git's pre-subcommand global flags (`-C <path>`, `-c <key>=<value>`, `--git-dir[=]<path>`, `-P`), including quoted values containing spaces, so that invocations like `git -C /repo push --force` are not silently bypassed.

  - **`watch-installs`** — package and dependency installation. **Block** rules shall cover: `curl … | sh`, `wget … | sh`, `npm install -g` / `--global`, `sudo pip[3] install`, and `brew install`. **Ask** rules shall cover: `npm install`, `yarn add`, `pnpm add`, `pip[3] install`, `cargo add`, `cargo install`, `go install`, `go get`, `gem install`, `composer require`, and `npx`.

  - **`watch-node`** — Node/JavaScript destructive primitives both inline (in `node -e`/`bun -e`/`deno`/`tsx`/`ts-node` bash invocations) and in `.js`/`.mjs`/`.cjs`/`.ts`/`.mts`/`.cts` file content authored via `Write`/`Edit`. **Block** rules shall cover: `fs.rmSync`/`rmdirSync`/`rm` of `/`/`~`/`$HOME`, `child_process` exec-family calls invoking `rm -rf /`, and `new Function(...)`. **Ask** rules shall cover: `fs.rm`/`rmSync` with `recursive: true`, `fs.unlink`/`unlinkSync`, `child_process.exec`/`execSync`, `vm.runInThisContext`/`runInNewContext`/`runInContext`, and `eval(...)`.

  - **`watch-pwsh`** — PowerShell destructive primitives both inline (in `pwsh -Command "..."` bash invocations) and in `.ps1`/`.psm1`/`.psd1` file content authored via `Write`/`Edit`. **Block** rules shall cover: `Format-Volume`, `Clear-Disk`, `Restart-Computer`, `Stop-Computer`, and `Invoke-WebRequest` piped to `Invoke-Expression`/`iex`. **Ask** rules shall cover: `Remove-Item -Recurse -Force` (with `except` for `~/.cache/`, `/tmp/`, `/var/tmp/` on the bash target), other `Remove-Item` forms, `Stop-Process -Force`, and `Set-Content`/`Out-File` overwriting sensitive paths (`/etc/`, `~/.ssh/`, `~/.aws/`).

  - **`watch-python`** — Python destructive primitives both inline (in `python3 -c "..."` bash invocations) and in `.py` file content authored via `Write`/`Edit`. **Block** rules shall cover: `shutil.rmtree` of `/`/`~`/`$HOME`, `pickle.loads`, `__import__('os').system`/`popen`, and `subprocess.*shell=True` containing `rm`/`dd of=/dev/`. **Ask** rules shall cover: other `shutil.rmtree`, `os.remove`/`os.unlink`, `os.system`, generic `subprocess.*shell=True`, `eval(`, and `exec(`.

  - **`watch-ruby`** — Ruby destructive primitives both inline (in `ruby -e` bash invocations) and in `.rb` file content authored via `Write`/`Edit`. **Block** rules shall cover: `FileUtils.rm_rf`/`rm_r`/`rm_f` of `/`/`~`/`ENV[...]`, `Marshal.load`/`restore`, and `YAML.load(...)` on input. **Ask** rules shall cover: other `FileUtils.rm_rf`, `File.delete`/`unlink`, `Kernel.system`/`exec` with a string literal, backtick exec with interpolation (`#{...}`), `eval(...)`, and `instance_eval`/`class_eval`/`module_eval`.

  - **`watch-secrets`** — credential and secret exfiltration. **Block** rules shall cover: reading SSH private keys (`cat … /.ssh/id_*`), reading cloud credentials (`.aws/credentials`, `.gcp/`, `.azure/`, `.config/gcloud`), and `echo`/`printf`-ing environment variables whose names match `SECRET|TOKEN|PASSWORD|API.?KEY|PRIVATE.?KEY`. **Ask** rules shall cover: reading files whose names suggest secrets, exporting secret-named env vars inline, reading `.env` files, reading `*.pem`/`*.key`/`*.crt`/`*.cert` files, dumping the environment via `env` or `printenv`, and reading dotfiles. Rules that match commands as full shell tokens (e.g. `env`, `printenv`) shall use shell-command boundaries (start/whitespace/`;`/`&&`/`|`/backtick/parens) rather than `\b` word boundaries, so that hyphenated tokens (`my-env`) do not defeat the match.

- **[SH-02]** Each shipped rule set that includes `target: bash` rules shall declare a top-level `filter` regex that short-circuits commands outside the rule set's domain.
- **[SH-03]** Each shipped rule set shall include `ref` URLs pointing to upstream tool documentation, vendor docs, or a CWE/OWASP entry.
- **[SH-04]** Each shipped rule set shall have a corresponding test file `tests/test-watch-<name>.sh` that exercises representative match/no-match cases.

## 11. Development & Testing (DEV)

- **[DEV-01]** `just test` shall run the full test suite via `tests/test-watchdog.sh`.
- **[DEV-02]** The test suite shall exercise each shipped rule set independently and shall also exercise engine-level behavior (decision aggregation, error handling, file/directory rules paths).
- **[DEV-03]** `just rules` shall launch an interactive Claude Code session with the local plugin loaded and the rules skill open.
- **[DEV-04]** `just docs-preview` shall serve the generated docs locally for review.

## 12. Implementation Notes (non-normative)

These describe how the current implementation satisfies the spec. They are
*not* requirements — they may change without bumping the spec version.

- The engine is a single Python script at `scripts/watchdog.py` with a minimal
  pure-Python YAML parser (no PyYAML dependency). The parser supports inline
  list syntax (`['.ps1', '.psm1']`) for the top-level `extensions` field.
- The hook command line is
  `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.py ${CLAUDE_PLUGIN_ROOT}/rules`,
  invoked from two `PreToolUse` matchers: `Bash` and `Write|Edit`.
- The SessionStart hook (`hooks/cli-freshness.sh`) is intentionally a no-op
  placeholder for future plugin-update self-checks; ClaudeWatch does not
  install a CLI shim, so the freshness-check pattern used by sibling plugins
  (`beacon`, `tack`, `logbook`) does not apply here.
- The rules-skill ID convention strips the `watch-` prefix from the rule set
  name (e.g. `watch-git` → `git-block-01`).
- Decision logging is implemented in `watchdog.py` as a single `_log_event`
  call after the decision is computed, guarded by `CLAUDEWATCH_LOG`. The UTC
  timestamp is the only clock in the script, and it is confined to the logging
  side channel — the decision path remains clock-free and deterministic.
- `/ClaudeWatch:learn` reads the log via `scripts/analyze-decisions.py`, a
  separate read-only, stdlib-only tool. The engine remains the only
  decision-making component; the analyzer never evaluates rules.

## 13. Future / Deferred (FUT)

- **[FUT-01]** Where a plugin-update self-check is implemented, the SessionStart hook shall verify `watchdog.py` emits the expected `hookSpecificOutput.permissionDecision` schema.
- **[FUT-02]** Where the user adds a custom rule set via `/ClaudeWatch:rules new`, the skill should offer to scaffold a matching test file in `tests/`.
- **[FUT-03]** Where multi-line YAML strings or nested anchors are required, the parser may switch to PyYAML; currently the minimal parser does not support these constructs.
- **[FUT-04]** Where the user customizes rules on an installed plugin via `/ClaudeWatch:rules` (including the `except` and demotion edits proposed by `/ClaudeWatch:learn`, which route through that skill), those edits shall survive plugin version upgrades. The skill writes to `${CLAUDE_PLUGIN_ROOT}/rules`, which for an installed plugin resolves to the version-scoped cache directory (e.g. `~/.claude/plugins/cache/chris-peterson/ClaudeWatch/0.8.0/rules/`); an upgrade installs a fresh version directory with its own shipped rules and the hook reads from the new root, orphaning prior edits. The decision log ([LOG-01]) already shows the durable shape: it lives in a fixed user directory (`~/.claude/claudewatch/`) outside the cache and so persists across upgrades. The gap closes by giving rule customizations the same treatment — a user rules directory alongside it (`~/.claude/claudewatch/rules/`) that the engine loads in addition to the shipped set (user rules winning on conflict), or a migration step on upgrade. Until then, only allow-list outputs of `/ClaudeWatch:learn` (written to `settings.json`) are durable on an installed plugin; rule edits are not. Edits made when running from a working copy via `claude --plugin-dir .` (per [DIST-03]) are already durable because `${CLAUDE_PLUGIN_ROOT}` is the git-tracked checkout, not the cache.
