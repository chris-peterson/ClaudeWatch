# ClaudeWatch — Specification (v1)

ClaudeWatch is a Claude Code plugin that enforces Bash command and script
safety via a `PreToolUse` hook. A generic engine evaluates regex rules loaded
from self-contained YAML rule sets and emits a single coalesced decision
(block / ask / allow) for each Bash, Monitor, Write, or Edit invocation. Rules may
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
- **LOG** — Decision logging (on by default, opt-out side channel)
- **HK** — Hook wiring
- **EXT** — Extensibility
- **SK** — Skills (`/ClaudeWatch:rules`, `/ClaudeWatch:learn`)
- **DOC** — Documentation
- **DIST** — Distribution / install
- **SH** — Shipped rule sets
- **DEV** — Development workflow

Requirements use [EARS syntax](https://alistairmavin.com/ears) — Ubiquitous (no
keyword), State-Driven (`While`), Event-Driven (`When`), Optional (`Where`),
Unwanted (`If…then`).

---

## 1. Engine (EN)

**Core contract:** Given tool input on stdin, the engine deterministically
emits exactly one of `{deny, ask, no-output}` and exits 0. The engine handles
these tool inputs: `Bash` and `Monitor` (both matched against the shell command
string they carry), `Write` (matched against the new file content), and `Edit`
(matched against the full post-edit file content).

- **[EN-01]** The engine shall read tool input from stdin as a single JSON object.
- **[EN-02]** When `tool_name` is not one of `"Bash"`, `"Monitor"`, `"Write"`, `"Edit"`, the engine shall produce no output and exit 0.
- **[EN-03]** When the relevant input field for the tool is empty or absent, the engine shall produce no output and exit 0. The relevant field is `tool_input.command` for `Bash` and `Monitor`, `tool_input.content` for `Write`, and `tool_input.new_string` (combined with `tool_input.file_path`) for `Edit`.
- **[EN-04]** If stdin is not valid JSON, then the engine shall produce no output and exit 0.
- **[EN-04a]** If stdin is not valid JSON, then the engine shall write the parse error to stderr before exiting so the failure is visible in transcripts.
- **[EN-05]** The engine shall accept a rules path as its first CLI argument.
- **[EN-05a]** Where the engine is invoked without a rules-path argument, it shall use the directory `../watches` relative to the engine script.
- **[EN-06]** When the rules path is a directory, the engine shall evaluate every `*.yml` file in that directory.
- **[EN-07]** When the rules path is a single file, the engine shall evaluate only that file.
- **[EN-08]** If the rules path does not exist, then the engine shall emit a `deny` decision with a "rules not found" reason that names the path.
- **[EN-09]** When the engine evaluates multiple rule files, it shall process them in a stable, sorted order.
- **[EN-10]** The engine's process exit code shall be `0` regardless of decision or error condition.
- **[EN-11]** The engine shall not require any third-party Python packages at runtime.
- **[EN-12]** When evaluating a `Write` input, the engine shall match rules against the value of `tool_input.content`.
- **[EN-13]** When evaluating an `Edit` input, the engine shall read the file at `tool_input.file_path`, apply the `old_string` → `new_string` substitution (all occurrences if `tool_input.replace_all` is true, otherwise the first occurrence), and match rules against the resulting full content. If the file cannot be read, the engine shall match against `tool_input.new_string` alone.
- **[EN-14]** When evaluating a `Monitor` input, the engine shall match rules against the value of `tool_input.command` and treat it as a `bash` input throughout — same rule targets ([RL-11]), same command-shape logging ([LOG-03]), same compound-command escalation ([OUT-08]). Rationale: the Monitor tool runs its `command` in the same shell environment as `Bash`, so a Monitor call the engine does not read is an unscreened shell. A Monitor invocation that carries a `ws` object instead of a `command` has no shell command to screen and falls under [EN-03].

### Decision logging (LOG)

Logging records each decision for later review (see [SK-13]–[SK-17]) and is on
by default — the decision log is the input the `/ClaudeWatch:learn` workflow
reads. It is separable from the decision: the engine's output is identical
whether or not logging is enabled.

- **[LOG-01]** By default — when `CLAUDEWATCH_LOG` is unset, or set to `1`/`true`/`on`/`yes` (case-insensitive) — the engine shall append one JSON record per evaluated input to the default path `~/.claude/claudewatch/decisions.jsonl`. Where `CLAUDEWATCH_LOG` is set to any other non-disabling value, the engine shall treat it as the destination path and append records there.
- **[LOG-02]** Where `CLAUDEWATCH_LOG` is set to `off`, `0`, `false`, `none`, or the empty string (case-insensitive), the engine shall write no log, and its decision and exit behavior shall be unchanged. This is the opt-out.
- **[LOG-03]** Each log record shall include the decision (`allow`/`ask`/`deny`), the matched rule reasons, a UTC timestamp, and the `session_id`, `cwd`, and active `permission_mode` from the hook input. For a `Bash` or `Monitor` input the record shall include the *command shape* (field `command_shape`) — the program name plus its leading subcommand tokens, with any leading `VAR=value` assignments and `sudo` dropped and the token run stopping at the first flag, path, or value (e.g. `git push --force origin main` → `git push`, `SECRET=… mysql -p… db` → `mysql`) — rather than the raw command string. The shape is what `/ClaudeWatch:learn` groups by ([SK-14]); recording it rather than the full command keeps inline secrets (credentials in flags, URLs, or assignments) out of the durable, plaintext log. For a `Write`/`Edit` input the record shall include the target file path rather than the file content.
- **[LOG-04]** Logging shall not influence the decision and shall not change the process exit code. If a log write fails, then the engine shall report the failure to stderr and otherwise continue, still emitting its decision.
- **[LOG-05]** The engine shall restrict the decision log to owner-only access — file mode `0600` and its parent directory mode `0700` — applied on each write so a pre-existing wider mode is corrected, so that the plaintext log is not readable by other accounts on the host. A failure to set the mode shall be handled as a log-write failure per [LOG-04].
- **[LOG-06]** The log shall begin with a header line `{"schema": N}` declaring the log's schema version, distinct from the per-input records of [LOG-01]. The current version is `2` (records store the command shape per [LOG-03]); version `1` is the pre-shape format that recorded the raw command string. On write, where the existing log has no header or declares a version other than the current one, the engine shall discard the existing log and start a fresh one with the current header, so that a log written under an earlier schema — which may contain raw commands with inline secrets — is not carried forward across an upgrade. Consumers of the log (the analyzer [SK-13] and the reset tool [SK-19]) shall ignore the header line. The discard applies to the active log only; archived logs ([SK-19]) are user-retained and left untouched.

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
- **[RL-11]** When evaluating a `Bash` or `Monitor` input, the engine shall evaluate only `target: bash` rules.
- **[RL-12]** When evaluating a `Write` or `Edit` input, the engine shall evaluate only `target: file-content` rules whose containing rule set's `extensions` list matches the input's file extension.
- **[RL-13]** If a rule's `target` value is neither `bash` nor `file-content`, then the engine shall emit a `deny` with a configuration-error reason naming the rule.
- **[RL-14]** If a YAML line in a rule set does not match any recognized field at its indent level, then the engine shall log a warning to stderr naming the rule set, the rule (when applicable), and the unrecognized line; the engine shall continue processing the remaining lines. This surfaces typos like `refrence:` instead of `ref:` that would otherwise be silently dropped.
- **[RL-15]** An `ask` rule may declare the optional inline-list fields `unless_condition` (named engine predicates) and `unless_regex` (regexes), which exempt the rule the same way `except` ([RL-07]) does. When the rule's `pattern` matches, the engine shall skip the rule (no ask emitted) if **any** `unless_regex` entry matches the input or **any** `unless_condition` predicate matches — OR'd together, and OR'd with `except`. If an `unless_regex` entry is an invalid regex, or an `unless_condition` names a predicate the engine does not ship, the engine shall emit a `deny` with a configuration-error reason naming the rule (an unknown predicate never silently fails to match). Both fields apply only to `ask` rules; on a `block` rule the engine shall log a warning to stderr and ignore them, mirroring [RL-08].
- **[RL-16]** The engine shall ship the `unless_condition` predicate `is_in_project_tree`: it matches (skipping the ask) when the input is a `bash` `rm` command whose every deletion target resolves strictly under an *anchor root*. The anchor roots shall be the working directory (`cwd`) supplied in the hook input and the project root supplied in the `CLAUDE_PROJECT_DIR` environment variable Claude Code exports to hook commands; `/` and the user's home directory shall be rejected as roots, as shall any non-absolute value. A relative target shall be resolved against `cwd` only, since that is the directory the shell itself would resolve it against; an absolute target may sit under either root. `cwd` follows the session's shell and therefore leaves the project the moment the session changes directory into a scratch area, while the project root holds still — anchoring on both keeps an in-repo delete exempt from either vantage point. The check shall be pure string resolution of the command's target paths against the roots — no filesystem access — so the decision stays deterministic; both roots are deterministic per-invocation inputs supplied by the host, so the core contract ([EN] determinism) holds. The predicate shall decline (the ask stands) whenever in-tree-ness cannot be established from the command text: no usable root; the command is compound (handled by [OUT-08]); the program is not `rm`; there are no targets; a target is an anchor root itself or a `.git` directory; a target carries an unresolvable marker (`~`, `$`, backtick, a glob `*`/`?`/`[`, or a `..` segment); or a target resolves outside every root.
- **[RL-17]** The engine shall ship the `unless_condition` predicate `is_ephemeral_scratch`: it matches (skipping the ask) when the input is a `bash` `rm` command whose every deletion target's final path segment names a directory a tool writes and can write again — `.playwright-mcp`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`. The premise is the directory's *identity* rather than its location, so unlike [RL-16] the predicate shall ignore where the target sits: deleting one of these loses nothing that re-running the tool does not reproduce, wherever on disk it is. Matching shall be on the final segment only, so a path *inside* such a directory is not exempt and the exemption cannot be widened by appending a subdirectory. The predicate shall decline on the same conditions [RL-16] does for compound commands, parse failures, a non-`rm` program, absent targets, and unresolvable markers, so a glob or variable can never stand in for the name.
- **[RL-18]** The engine shall ship the `unless_condition` predicate `is_recoverable`: it matches (skipping the ask) when the input is a `bash` `rm` command whose every deletion target satisfies [RL-16]'s pure-string under-root resolution **and** is provably restorable from git after the delete: every target is tracked, none is a submodule, and no file under any of them is untracked, ignored, or modified without being committed. A submodule is declined rather than answered for — the superproject records only the commit it points at, so work uncommitted inside it is not visible to the checks made here. Unlike [RL-16] and [RL-17] this predicate reads the filesystem: its checks shall be read-only, shall be bounded by a timeout, and shall fail closed — the predicate declines (the ask stands) whenever a check cannot complete, whether the tool is absent, the timeout elapses, or the command reports failure. This is the sole exemption to the no-filesystem-access property [RL-16] states, and it is scoped to this predicate: the decision stays a pure function of the command, the roots, and the on-disk state those name, with no clock, randomness, or network.

## 4. Output Decisions (OUT)

The engine emits at most one decision per invocation.

- **[OUT-01]** When emitting a decision, the engine shall write a single JSON object to stdout matching the Claude Code `hookSpecificOutput` schema with `hookEventName: "PreToolUse"` and `permissionDecision` set to `"deny"` or `"ask"`.
- **[OUT-02]** The engine shall format each violation canonically as `<rule-name>: <reason>` (just `<reason>` when the rule has no name), with ` — <ref>` appended when `ref` is present. The rule-set name is omitted — the `ref` link supplies that context. This canonical form is what both the displayed reason and the decision log (`[LOG-03]`) carry.
- **[OUT-03]** When any block rule matches in any rule set, the engine shall emit a single `deny` decision aggregating all block reasons, separated by newlines.
- **[OUT-04]** When no block rule matches and at least one ask rule matches in any rule set, the engine shall emit a single `ask` decision aggregating all ask reasons, separated by newlines — subject to the compound-command escalation in [OUT-08].
- **[OUT-05]** When no rule matches, the engine shall produce no stdout output (allow-by-default).
- **[OUT-06]** *(retired in 0.18.0)* — ~~the ask prompt rendered the `<reason>` prose as an OSC 8 terminal hyperlink to the `ref`, with `CLAUDEWATCH_HYPERLINKS` as the opt-out.~~ Claude Code 2.1.235 began sanitizing hook-supplied reason strings, replacing every control character with U+FFFD, so the escape reached the user as visible garbage instead of a link. Both paths now use the canonical ` — <ref>` form of `[OUT-02]`, and `CLAUDEWATCH_HYPERLINKS` is gone.
- **[OUT-07]** A **deny** decision's `permissionDecisionReason` shall end with the ` [plugin:ClaudeWatch]` source tag — but the logged reasons (`[LOG-03]`) shall not. Claude Code annotates ask prompts with the originating plugin but leaves deny errors unattributed, so the engine appends the tag itself on the deny path to keep the source visible. Ask decisions shall not carry the tag (the host supplies it).
- **[OUT-08]** When the coalesced decision for a `Bash` or `Monitor` input is `ask` and the command is *compound* — it contains a shell control operator (`|`, `;`, newline, `&&`, `$(`, or backtick) outside any single- or double-quoted span — the engine shall escalate the decision to `deny` and prepend a note stating the ask was escalated because a piped or chained command can be auto-approved segment-by-segment by the host allow list (skipping the confirmation) and that the guarded command should be run on its own to be prompted. Rationale: Claude Code does not honor a `PreToolUse` hook's `ask` for a compound command whose segments each match a host `allow` rule — it auto-approves the pipeline before the prompt surfaces — so an un-escalated `ask` is silently bypassed; a `deny` is honored through the pipe. The escalation applies only to an `ask` decision (a `deny` already survives, and `allow`/no-match stays silent per [OUT-05]) and only to shell-command inputs — `Bash` and `Monitor` ([EN-14]); `Write`/`Edit` are single operations, not shell pipelines. A `Monitor` command runs unattended and repeats on one approval, so an ask-tier command inside one escalates on the same terms; the way to be prompted is the same, run the guarded command as its own `Bash` call. Operators inside quoted spans are string data, not command boundaries, and shall not trigger escalation.

## 5. Hook Wiring (HK)

- **[HK-01]** The plugin shall register `PreToolUse` hooks that invoke the engine against the plugin's `watches/` directory for the `Bash`, `Monitor`, `Write`, and `Edit` tools. Matchers may be combined via regex alternation (e.g. `matcher: "Write|Edit"`).
- **[HK-02]** *(retired in 0.18.0)* — ~~the plugin shall register a `SessionStart` hook for plugin-update self-checks.~~ Never implemented; the placeholder hook was removed with it. The ambient-guidance `SessionStart` hook of [HK-04] is unaffected.
- **[HK-03]** The plugin shall declare its hooks in `hooks/hooks.json`.
- **[HK-04]** The plugin shall register a `SessionStart` hook that emits ambient guidance into the session context advising that a consequential command be run as its own Bash call rather than piped or chained, so the compound-command escalation ([OUT-08]) is avoided before it triggers. The guidance shall be sourced from `rules/*.md` so it can be edited without changing the hook.

## 6. Extensibility (EXT)

- **[EXT-01]** Where a new `*.yml` file is added to the `watches/` directory, the engine shall auto-discover it on the next invocation without any configuration change to `hooks.json`.
- **[EXT-02]** Where a rule set is renamed from `*.yml` to `*.yml.disabled`, the engine shall stop loading it on the next invocation.
- **[EXT-03]** New rule sets shall not require code changes to the engine.

## 7. Skills (SK)

The plugin ships interactive Claude Code skills that surface and edit rules
without leaving the session.

> **[SK-01]** *(retired in 0.16.0)* — ~~the `/ClaudeWatch:help` skill provided an overview of the plugin.~~ It was removed; that overview now lives in the README and the docs site.

### `/ClaudeWatch:rules`

- **[SK-02]** Where the user invokes `/ClaudeWatch:rules`, the skill shall list every enabled rule set with two tables (block, ask) using stable IDs of the form `<short-name>-block-NN` and `<short-name>-ask-NN` (zero-padded).
- **[SK-03]** When listing rule sets, the skill shall also list any disabled rule sets (`*.yml.disabled`).
- **[SK-04]** Where the user passes `--list`, the skill shall list rules and exit without entering the edit loop.
- **[SK-05]** When the user enters an edit command, the skill shall accept one operation per turn and loop until the user enters `done`. The supported operations are: `<id>:block` (move rule to block), `<id>:ask` (move rule to ask), `<id>:allow` (remove the rule), `add` (add a new rule), `disable <name>` (disable a rule set), `enable <name>` (re-enable a disabled rule set), and `new` (create a new rule set).
- **[SK-06]** Before writing edits, the skill shall scan for duplicate patterns, shadowing patterns, and cross-section conflicts (same pattern in both block and ask) and shall report any findings to the user.
- **[SK-07]** Before writing edits, the skill shall present a preview of the updated rule tables and shall require explicit confirmation (`yes` / `edit` / `abort`) from the user.
- **[SK-08]** When applying edits, the skill shall write only modified rule set files and shall preserve the standard YAML format.
- **[SK-09]** When the user issues `disable <name>`, the skill shall rename `watches/<name>.yml` to `watches/<name>.yml.disabled`.
- **[SK-10]** When the user issues `enable <name>`, the skill shall rename `watches/<name>.yml.disabled` to `watches/<name>.yml`.
- **[SK-11]** When the user issues `new`, the skill shall create a new `watches/watch-<name>.yml` (the name shall start with `watch-`) with the standard YAML format.
- **[SK-12]** After applying changes, the skill shall run `tests/test-watchdog.sh` and shall report any failures.

### `/ClaudeWatch:learn`

The learn skill aggregates the decision log ([LOG-01]–[LOG-04]) into a batch
of proposed permission changes, so the user vets accumulated prompts once
rather than per command.

- **[SK-13]** Where the user invokes `/ClaudeWatch:learn`, the skill shall analyze the decision log and present its proposals. If no log exists, the skill shall make no changes and shall report why: when logging is disabled (`CLAUDEWATCH_LOG` set to an opt-out value per [LOG-02]) it shall warn that disabling logging disables `/ClaudeWatch:learn` and explain how to re-enable; otherwise (logging on by default, but no records yet) it shall explain that no sessions have run with the hook active.
- **[SK-14]** The skill shall present three groups: **allow candidates** (frequently-allowed commands not covered by the current allow list), **ask candidates** (commands ClaudeWatch repeatedly asks about, with the matched rule), and a **deny summary** (blocked commands grouped by reason, informational). An allow candidate shall name the tool its records came from and propose a permission rule for that tool (`Bash(…)` or `Monitor(…)`), and shall be judged already-covered only against existing rules for the same tool: the host treats the two as separate rule families, so a `Bash` rule does not cover the same command issued through `Monitor`.
- **[SK-15]** The skill shall accept an optional time window (e.g. `--since 1d`) and forward it to the analysis.
- **[SK-16]** Before writing any change, the skill shall present the exact edits and require explicit confirmation, and shall apply only the items the user approves.
- **[SK-17]** The skill shall apply approved allow-list additions to a `settings.json` whose scope (user or project) the user selects, shall route rule changes (`except` additions, demotions) through `/ClaudeWatch:rules`, and shall not modify deny-summary items automatically.
- **[SK-18]** The analysis shall report the window its proposals are drawn from: the number of decision records considered, the count of distinct sessions among them, and the time span from the oldest to the newest record. The skill shall surface this so the user can weigh how much history backs the suggestions.
- **[SK-19]** The skill shall offer to reset the decision log after the user has applied their chosen changes, so that the next analysis measures from the post-change baseline rather than re-surfacing already-dispositioned commands. Reset shall **archive** the current log by default — moving it to a fixed user directory (`~/.claude/claudewatch/archive/`, beside the durable log per [LOG-01]) so the prior history is recoverable — and shall support a `--hard` mode that deletes it outright. Where logging is disabled ([LOG-02]) or no log exists, reset shall make no change and shall report why. Reset shall report what it cleared (record count and span).

## 8. Documentation (DOC)

- **[DOC-01]** The plugin shall ship a Docsify documentation site under `docs/`.
- **[DOC-02]** `just docs` shall regenerate the rules-reference page from the YAML rule files.
- **[DOC-04]** The documentation shall include a YAML schema reference covering top-level fields and rule fields.
- **[DOC-05]** `just docs` shall regenerate a prompts page, linked from the docs-site sidebar, approximating the Claude Code permission prompt each rule produces — block rules as an outright rejection, ask rules as a confirmation prompt — with the reason prose linking to the rule's `ref`.

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

  - **`watch-files`** — generic destructive filesystem operations. **Block** rules shall cover: `rm -rf /`, `rm -rf /*`, `chmod 777`, `mv … /dev/null`, and `shred`. **Ask** rules shall cover: recursive `rm -rf`, recursive `rm -r`, `mv` from a root-level path, `chmod`, and `chown`. The two recursive-rm ask rules shall carry an `unless_regex` exempting paths under `~/.cache/`, `/tmp/`, or `/var/tmp/`, and `unless_condition` entries of `is_in_project_tree` and `is_ephemeral_scratch` ([RL-15]–[RL-17]), so a recursive delete confined to the working tree — recoverable from git history — is allowed, as is one that names a regenerable tool directory wherever it sits, while a delete reaching outside the tree still prompts.

  - **`watch-git`** — destructive git operations. **Block** rules shall cover: `git push --force` (excluding `--force-with-lease`), `git checkout .`, `git restore .`, `git clean -f`, `git stash drop`, `git stash clear`, and `git reflog expire/delete`. **Ask** rules shall cover: `git reset --hard`, `git checkout -- <file>`, `git commit`, `git stash`, `git push`, `git push --force-with-lease`, `git push --delete` (remote-branch delete, via `--delete`/`-d`/the `:branch` colon refspec), and `git branch -D`. The split follows the no-recovery/recoverable line: deleting a remote branch leaves no remote reflog to recover from, yet you can re-push from a local copy, so it asks rather than blocks; `git branch -D` and `--force-with-lease` are likewise recoverable (local reflog, stale-ref protection) and so ask. Stage-only operations (`git add`, `git rm`, `git rm --cached`, `git reset` without `--hard`) are intentionally unwatched — staging is recoverable, and prompting on it is noise. Each rule shall match through git's pre-subcommand global flags (`-C <path>`, `-c <key>=<value>`, `--git-dir[=]<path>`, `-P`), including quoted values containing spaces, so that invocations like `git -C /repo push --force` are not silently bypassed.

  - **`watch-installs`** — package and dependency installation. **Block** rules shall cover: `curl … | sh`, `wget … | sh`, `npm install -g` / `--global`, `sudo pip[3] install`, and `brew install`. **Ask** rules shall cover: `npm install`, `yarn add`, `pnpm add`, `pip[3] install`, `cargo add`, `cargo install`, `go install`, `go get`, `gem install`, `composer require`, and `npx` remote-fetch forms (`-y`/`--yes`, `-p`/`--package`, or a versioned/scoped spec such as `pkg@version` or `@scope/pkg`). A bare `npx <tool>` that runs an already-installed binary is allowed, since it executes local code no differently from `npm run`; only the forms that download and run a remote package prompt.

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
  `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.py ${CLAUDE_PLUGIN_ROOT}/watches`,
  invoked from two `PreToolUse` matchers: `Bash|Monitor` and `Write|Edit`.
- The ambient-guidance emission ([HK-04]) is a second SessionStart hook,
  `hooks/emit-rules.sh`, which prints a `# Ambient rules from the ClaudeWatch
  plugin` header followed by each `rules/*.md` file to stdout. Claude Code
  adds SessionStart stdout to context on startup, resume, and compaction, so
  the guidance persists across a compaction. This mirrors the `emit-rules.sh`
  pattern in sibling plugins (`beacon`, `anchor`), which also keep their
  ambient markdown under `rules/`. The YAML rule sets the engine evaluates
  live in a separate `watches/` directory ([HK-01]), so the two never collide.
- The rules-skill ID convention strips the `watch-` prefix from the rule set
  name (e.g. `watch-git` → `git-block-01`).
- Decision logging is implemented in `watchdog.py` as a single `_log_event`
  call after the decision is computed; it is on by default and `CLAUDEWATCH_LOG`
  only redirects the path or opts out. The UTC timestamp is the only clock in
  the script, and it is confined to the logging side channel — the decision path
  remains clock-free and deterministic.
- `/ClaudeWatch:learn` reads the log via `scripts/analyze-decisions.py`, a
  separate read-only, stdlib-only tool. The engine remains the only
  decision-making component; the analyzer never evaluates rules.
- The compound-command detection ([OUT-08]) strips quoted spans with a simple
  regex before scanning for shell operators. It does not parse escaped quotes
  (`\"`) or `$'…'`, so an operator hidden behind such quoting may go undetected.
  This is safe by construction: the escalation only ever tightens an `ask` into
  a `deny`, so a missed compound form degrades to the existing `ask` (the
  pre-escalation behavior), never to something weaker. The `block`/`ask`
  pattern matching itself runs on the full, unstripped command, so quote
  stripping does not affect which rules fire — only whether a matched `ask` is
  escalated.
