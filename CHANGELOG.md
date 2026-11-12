# Changelog

## Unreleased

- Reading a file under `~/.claude/plugins/data/`, where each plugin keeps its
  persistent state, no longer asks through `read dotfiles`, matching the
  existing exemption for `~/.claude/plugins/cache/`. A file there with a
  secret-like name still asks.

## 1.0.0

### Breaking

- `/ClaudeWatch:learn` no longer proposes allow rules. ClaudeWatch's decisions
  are `ask` and `deny`, and what it lets through is Claude Code's to decide, so
  a learn pass now covers the rules that ask most and the blocks in your way,
  and never writes to `settings.json`. `analyze-decisions.py` drops its
  `allow_candidates` bucket and its `--settings` flag.
- The README no longer recommends broadening your Bash allow list
  (`Bash(python3 *)`, `Bash(aws *)`) with ClaudeWatch as the safety net.
- The guard fails closed. When the hook can't run (no `python3`, a `python3`
  that isn't a working interpreter, a crash, a timeout), every Bash, Monitor,
  Write, and Edit call is blocked instead of running unscreened. README's
  Installation section lists the prerequisites; on Windows, `python3` must
  resolve in Git Bash to a real interpreter, not the Microsoft Store alias.
- `$(` and backticks inside double quotes count as compound, since the shell
  runs them there. So `rm -rf "$(mktemp -d)"`, `rm -rf /tmp/x && mkdir -p /tmp/x`,
  and the heredoc commit shape `git commit -m "$(cat <<'EOF' … EOF)"` are
  blocked. Write the message to a file and run `git commit -F <path>`.
- `/ClaudeWatch:rules` changes how the rules apply to you instead of editing
  them: it writes `~/.claude/claudewatch/overrides.yml`, which survives plugin
  upgrades, and can move a rule between block and ask or turn a rule or rule set
  off. Adding rules and rule sets, and the `.yml.disabled` toggle, are gone from
  the skill. Edits made the old way, in the plugin's `watches/` folder, were
  lost at the last upgrade anyway; redo them with the skill.

### Features

- Rule overrides survive upgrades. The engine applies
  `~/.claude/claudewatch/overrides.yml` on top of the shipped rules; a malformed
  file denies every screened call until fixed, and an override naming a rule an
  upgrade removed is ignored and reported. Each session start logs every
  difference from the shipped rules to the decision log. `/ClaudeWatch:learn`
  now proposes these overrides from your decision history.
- `/ClaudeWatch:unattended` for handing a session work and stepping away. The
  agent decides, logs each call in `NOTES.md`, and ends with a review map. While
  the session is marked, ClaudeWatch's `ask` tier blocks in every mode (`auto`
  included), and Claude Code permission prompts and `AskUserQuestion` are
  denied at once, so nothing waits on a person who isn't there. The prompt and
  question hooks fail closed, in attended sessions too. A bare `git add`, `git commit`,
  `git switch`, or `git checkout -b` still goes through so the run can commit
  its work locally, and each one is logged as an `ALLOW` line. The first prompt
  you type clears the mark.
- A new `watch-kill` rule set asks before `pkill` and `killall`, which kill
  every process matching a name or pattern (with `pkill -f`, the whole command
  line) and can take down other Claude Code sessions, editors, or dev servers.
  It matches them run as a command, so `grep pkill notes.md` doesn't prompt.
- A new `watch-su` rule set blocks `sudo` and `su`. With a cached sudo
  timestamp or a `NOPASSWD` entry, `sudo` runs as root without a password
  prompt. `sudo pip install` is covered here now, so watch-installs no longer
  carries its own rule for it.
- watch-installs blocks the rest of the system package changes: `brew upgrade`,
  `uninstall` (and `remove` / `rm`), and `reinstall` alongside `brew install`;
  `choco install`, `upgrade`, and `uninstall`; and `apt install` /
  `apt-get install`.
- The decision log files each matched rule under the part of the command it
  matched: records carry `matched_shapes` beside `matched`, so
  `cat msg.txt && git commit -F msg.txt` is filed under `git commit`, not `cat`.
  `command_shape` skips `cd` and comment lines, so `cd repo && rm -rf build` is
  `rm`. `/ClaudeWatch:learn` groups by the matched part, and reads older records
  by their `command_shape`.
- A new `watch-exec` rule set blocks running code nobody can read first: a
  download run through `$(curl …)` or `<(curl …)` or piped to an interpreter
  such as `python` or `node`, a `base64 -d` payload piped to a shell, and
  shells attached to a network connection (`nc -e`, `socat … exec:`,
  `/dev/tcp/`).
- watch-files blocks writes to a raw disk run as a command (`dd of=/dev/sda`,
  `mkfs /dev/sdb1`, `> /dev/sda`, `diskutil eraseDisk`), not only inside `.sh`
  files.
- More commands with no recovery are blocked: `git gc --prune=now`,
  `git prune`, and `git filter-branch`/`filter-repo` (watch-git);
  `gh`/`glab repo delete`, `terraform`/`tofu`/`pulumi destroy`, and
  `kubectl delete` of a namespace or with `--all` (new watch-remote);
  `npm unpublish` and `gem yank` (new watch-publish, which also asks before
  `npm publish`); and `shutdown`/`reboot`, `crontab -r`, and fork bombs (new
  watch-host).
- ClaudeWatch protects itself from the agent. A new `watch-self` rule set
  blocks every way the agent can loosen it: writing or deleting under
  `~/.claude/claudewatch/`, running `overrides.py` to move a rule to `ask` or
  `off` or to reset, `unattended.py off`, disabling or uninstalling the plugin,
  and a settings file that disables it or every hook. `/ClaudeWatch:rules` and
  `/ClaudeWatch:learn` print a loosening change for you to type with a `!`
  prefix, which runs it without passing through ClaudeWatch, instead of
  running it. Rules can now match a Write or Edit's file path
  (`target: file-path`), which is how the overrides file is guarded even
  against a Write that empties it.
- Guarded commands are caught however the shell spells them: `"git" commit`,
  `g\it commit`, `git "commit"`, a subshell `(git push)`, and a command ended
  by `;`, `|`, or a backtick instead of a space (`git commit;echo done`).
- Secret reads are screened for any reader, not just `cat`: `tac`, `xxd`,
  `less`, `head`, `strings`, a bare `< ~/.aws/credentials`, and others. The
  cloud-credentials block also covers the AWS SSO and CLI caches. These rules
  are renamed from `cat …` to `read …`.

### Fixes

- Input the engine can't read (a malformed payload, a non-string command,
  bytes that aren't UTF-8) and any internal error now deny the call instead of
  crashing and letting it run.
- Edits to a file that isn't UTF-8 are screened. A Latin-1 or binary file
  crashed the hook, a UTF-16 file was never screened, and a CRLF file could
  hide `curl … | bash` across a line break.
- `rm --recursive --force /` and `rm -r -f /` are caught like `rm -rf /`, and
  so is a recursive `rm` inside a quoted script: `bash -c "rm -rf /"`,
  `eval "rm -rf ~/Documents"`.
- The scratch-path exemption checks every `rm` target and resolves `..`, so
  `rm -rf /tmp/../Users/foo` and `rm -rf /tmp/build ~/Documents` no longer
  skip the prompt. `/private/tmp`, where macOS resolves `/tmp`, counts as
  scratch.
- `git clean --force` and `git branch --delete --force` (or `-d -f`, `-df`)
  are caught like their short forms, and every rule naming a long option also
  matches the prefixes git and GNU `rm` accept for it: `git reset --h` resets
  hard and `git clean --f` deletes, and both ran unguarded.
- A plugin installed under a path containing a space now runs its hooks.
  Before, the hook command split at the space and nothing was screened.
- The secret-like filename rule checks the file's own name, not its
  directories, and skips source files (`.cs`, `.py`, `.ts`, and the like), so
  `cat SecurityTokenImpl/Domain/Jwt/JwtValidator.cs` no longer asks.
  `cat -n config/token.json` and `cat README.md secrets.json` now ask.
- `env` asks only when it prints the environment. `env A=1 make` and
  `env -i bash` no longer ask; `env`, `env -u PATH`, and `printenv` still do.
- `git stash list` and `git stash show` no longer ask; they only read the
  stash. Every other `git stash` form still asks.
- The `mv /` ask fires only for `/` itself and top-level system paths (`/etc`,
  `/usr`, `/var`, `/Library`, and the like), not for any absolute path. Moving
  files under a home directory, `/tmp`, `/private/tmp`, or `/var/folders` no
  longer prompts.
- A bare `VAR=value` command no longer writes its value into the decision log
  as the command shape.
- A program spelled by its path (`/bin/rm`, `/bin/mv`, `/usr/bin/tee`) is
  screened as its name, so every rule that names the program catches it:
  `/bin/rm -rf /` and `/bin/mv ~/.claude/claudewatch/overrides.yml /tmp/x`
  ran unguarded.

### Other

- The docs explain what an `ask` actually does in each permission mode. Since
  Claude Code 2.1.284, a session with no configured mode starts in `auto`,
  where an `ask` runs without a prompt. Set
  `"permissions": { "defaultMode": "default" }` to get the prompts back. The
  ambient note no longer tells agents that a bare guarded command will prompt.
- The docs describe the two ask-tier changes in Claude Code 2.1.319:
  `permissions.denyInsteadOfPrompting` denies an `ask` in every mode, and `auto`
  with telemetry or feature flags off asks about or denies calls the auto-mode
  server can't check instead of running them unprompted. The ambient note,
  README, `/ClaudeWatch:learn`, and `SPEC.md` `[OUT-04]` carry both.
- The same places name a mod's own tool call (`$.tool.call`, Claude Code
  2.1.321) as a case where an `ask` reaches nobody: the call does not run, and
  a `deny` holds as well.
- The test suite runs in CI on Linux and macOS. The plugin has a new icon and
  a one-line description that matches on every surface.

## 0.18.0

### Breaking

- The `is_relative_to_cwd` unless-condition is now `is_in_project_tree`. A
  custom rule set still naming the old one config-error **denies** every command
  its rule matches, so rename it in your `watches/*.yml`.

### Features

- `Monitor` commands are screened against the same rules as `Bash` — it runs its
  command in the same shell, so a guarded command in a watch loop is caught
  rather than running unattended on one approval.
- `rm -rf` on a regenerable tool directory — `__pycache__`, `.pytest_cache`,
  `.mypy_cache`, `.ruff_cache`, `.playwright-mcp` — no longer prompts, wherever
  on disk it sits. Names only: a path *inside* one is not exempt.
- The in-tree `rm` exemption honors `CLAUDE_PROJECT_DIR` alongside the working
  directory, so an in-repo delete still skips the prompt after the session has
  `cd`'d into a scratch directory.
- Rule authors get an opt-in `is_recoverable` condition, which asks git whether
  it can actually restore the targets instead of trusting where they sit — a
  workspace root grouping several checkouts is not itself a repo, and a delete
  there has no history behind it.

### Fixes

- Permission prompts show the rule reference as plain text. Claude Code 2.1.235
  routes the prompt's reason through a sanitizer that maps control characters to
  U+FFFD, so the terminal-hyperlink escape reached the dialog as a literal
  `]8;;<url>` wrapped in replacement characters
  ([#22](https://github.com/chris-peterson/ClaudeWatch/issues/22)).

### Other

- Build and CI run on shipyard v2: `plugin.json`, `hooks.json`, and the docs
  site are projected from `plugin.yml` and `hooks/hooks.yml` by CI, and `SPEC.md`
  is published at `/spec`.
- The `cli-freshness` SessionStart hook is retired.

## 0.17.2

Plugin metadata and skill-hygiene fixes from a plugin-dev best-practices scan.

- **`plugin.json` now carries `homepage`.** The generator projects
  `marketplace.homepage` into the descriptor, so a standalone (non-marketplace)
  install exposes the documented homepage field.
- **`icon` points at the rendered asset** — corrected from the unused
  `docs/logo.svg` to `docs/favicon.svg`.
- **Skills fail loud on a missing plugin root.** Both `/ClaudeWatch:learn` and
  `/ClaudeWatch:rules` use `${CLAUDE_PLUGIN_ROOT}` with no silent cwd fallback.
- **Sharper skill descriptions** and a pointer to `SCHEMA.md` as the
  authoritative rule-YAML reference.
- Documented the intentional PascalCase plugin name; parked a per-repo
  self-marketplace idea as `FUT-06`.

## 0.17.1

- Both `/`-invoked skills (`learn`, `rules`) are now marked `disable-model-invocation`, dropping their descriptions from every session's always-resident context. They stay available via `/ClaudeWatch:learn` and `/ClaudeWatch:rules`; Claude no longer auto-loads them.
- Skill metadata polish: explicit `name:` frontmatter on both skills, and the `rules` skill no longer documents a non-interpolating `$ARGUMENTS` token (skills don't substitute it).
- Docs: pruned stale `/ClaudeWatch:help` references (retired in 0.16.0) from `AGENTS.md` and `STATUS.md`, and removed a drift-prone index count.

## 0.17.0

### Features
- Recursive `rm` deletes confined to your working directory no longer prompt — they're recoverable from git history, so the confirmation was just noise. A delete that reaches outside the working directory still asks: absolute out-of-tree paths, `..` escapes, home (`~`) paths, globs or variables that can't be resolved, the working directory itself, and any `.git` directory.
- Rule authors get two new list-valued ask-rule exemptions, `unless_condition` (named engine predicates) and `unless_regex` (regexes), plus the first shipped predicate, `is_relative_to_cwd`. They sit alongside the existing `except`, and any match skips the prompt.

### Other
- Inline YAML lists are now quote-aware, so a comma inside a quoted item (e.g. a `{1,2}` regex quantifier) survives parsing.
- SPEC, SCHEMA, and the generated rules reference document the new fields and predicate.

## 0.16.0

### Removed
- The `/ClaudeWatch:help` skill is removed — its overview duplicated the README and docs site while carrying always-resident description weight. Use `/ClaudeWatch:rules` to view and edit rules, and `/ClaudeWatch:learn` to cut prompt fatigue from your decision log; the overview lives in the README and docs site.

### Other
- Trimmed the `description` frontmatter of the remaining skills (`learn`, `rules`) to cut the always-resident context cost. `learn` keeps the natural-language cues ("what keeps prompting me", "reduce prompts").

## 0.15.4

### Fixes

- `watch-installs` now prompts on `npx` only for the forms that actually download and run a remote package — `-y`/`--yes`, `-p`/`--package`, and versioned or scoped specs (`pkg@version`, `@scope/pkg`). A bare `npx <tool>` that runs an already-installed binary is allowed, since it executes local code no differently from `npm run` — cutting the prompt friction from routine dev-loop commands like `npx tsc`, `npx eslint`, and `npx playwright test`.

## 0.15.3

### Fixes

- Git branch-delete guards now track how recoverable each delete is. Force-deleting a *local* branch (`git branch -D`) was a hard block, but it's recoverable from the reflog, so it now prompts instead of blocking. Deleting a *remote* branch (`git push --delete`, `-d`, or the `:branch` colon refspec) now prompts with an accurate reason — the remote keeps no reflog — instead of falling through to the generic push prompt's misleading "publishes commits" message. Force-push stays the one git operation blocked outright.

## 0.15.2

### Fixes
- **Ambient rule reframed around the pipe/chain reflex.** The session-start nudge now leads with the actionable habit — run a guarded command (commit, push, install, destructive op) on its own rather than folding it into a pipe or `&&` chain — instead of opening with the escalation mechanics.
- **Dropped a private-repo reference from the `cli-freshness.sh` comment.** The SessionStart hook's comment pointed at a private repo path; ClaudeWatch is public and the comment already explains why the hook is a no-op, so the pointer is removed.

## 0.15.1

**Full Changelog**: https://github.com/chris-peterson/ClaudeWatch/compare/v0.15.0...v0.15.1

## 0.15.0

## Privacy hardening for the decision log

The `/ClaudeWatch:learn` decision log now records the **command shape** (the
program plus its leading subcommand tokens, e.g. `git push`, `aws s3 cp`)
instead of the full command. Inline secrets — bearer tokens, `-p<password>`,
credentials in URLs — no longer reach the plaintext log. The shape is all
`/ClaudeWatch:learn` groups by, so the workflow is unchanged.

### Changes
- **Command-shape logging** (LOG-03): Bash decisions record the shape, not the
  raw command, keeping inline secrets out of the durable log.
- **Owner-only permissions** (LOG-05): the log and its directory are restricted
  to `0600`/`0700`, applied on every write so a pre-existing wider mode is corrected.
- **Schema-versioned log** (LOG-06): a `{"schema":2}` header is written; on the
  first write after this upgrade, a pre-shape log (which held raw commands) is
  discarded and a fresh shape-only log started, so plaintext history doesn't
  carry forward.
- **Analyzer fix**: allow-list suppression keys on the command shape rather than
  the raw command, so a `VAR=…; echo …` command is no longer wrongly re-proposed
  as an allow candidate.

No action needed — an existing log is replaced automatically on the next
decision after upgrade.

## 0.14.0

### Fixes
- **Piped and chained commands no longer bypass the `ask` tier.** Claude Code does not honor a `PreToolUse` hook's `ask` decision for a *compound* command (a pipe or chain like `git push --force-with-lease 2>&1 | tail`) whose segments each match a host `allow` rule — it auto-approves the pipeline before the prompt surfaces, so a guarded ask-tier command (`commit`, `push`, `push --force-with-lease`, `stash`, `env`, …) ran unprompted whenever it was piped. A `deny` is honored regardless. The engine now escalates an `ask` to a `deny` when a Bash command is compound — it contains an unquoted shell control operator (pipe, `;`, newline, `&&`, `$(`, or backtick) — with a message to re-run the guarded command on its own to get the prompt. Operators inside quoted spans (a pipe in a commit message, a `;` in a `python3 -c "…"` argument) are stripped first, so they don't false-trigger. The escalation only ever tightens `ask`→`deny` and is bash-only; bare commands prompt as before (see `SPEC.md` `[OUT-08]`). Closes #14.

## 0.13.4

### Fixes
- `git checkout -- <file>` now prompts instead of being blocked outright. Reverting a specific file's working-tree changes is a routine, recoverable operation, and the hard block stood in the way of deliberate single-file reverts. It now asks for confirmation — like `git reset --hard`, the sibling "discards changes with no recovery" op — while `git checkout .` (which discards *all* working-tree changes) stays a block.

## 0.13.3

Switch to a proper release process

## 0.13.2

### Other
- **`plugin.yml` is now the canonical descriptor.** `.claude-plugin/plugin.json` is generated from it by `scripts/gen-plugin-json.py` (`just plugin-json`), with a pre-commit hook (`just install-hooks`) keeping the two in sync. `version` is authoritative in `plugin.yml`. The `suite:` block also feeds the bridge.ai marketplace catalog.
- **Tag-based release publishing.** Releasing now tags the merge commit `v<version>`; `.github/workflows/release.yml` verifies `plugin.json` is in sync and notifies the bridge.ai marketplace to rebuild via `repository_dispatch`. This supersedes the former tag-free, main-only model.

## 0.13.1

### Fixes
- **Deny prompts show the ref URL again.** Claude Code renders a deny reason through its error path, which strips the OSC 8 escape introduced in 0.13.0 without making it clickable — so a blocked `git push --force` displayed `overwrites shared remote history` with no way to reach the docs. Deny decisions now always use the plain `<rule>: <reason> — <url>` form so the `ref` is visible and copyable; ask prompts keep the clickable hyperlink (the host renders OSC 8 there). `CLAUDEWATCH_HYPERLINKS` still controls the ask path; deny is plain regardless (see `SPEC.md` `[OUT-06]`).
- **Deny messages carry the `[plugin:ClaudeWatch]` source tag.** Claude Code annotates ask prompts with the originating plugin but leaves deny errors unattributed, so a blocked command didn't show which plugin made the call. Deny reasons now append the same ` [plugin:ClaudeWatch]` tag the host shows on ask prompts; the decision log keeps the canonical untagged form (see `SPEC.md` `[OUT-07]`).

## 0.13.0

### Features
- **Permission prompts link the reason prose instead of printing the ref URL.** When an ask/block rule fires, the displayed reason reads `<rule>: <reason>` where the `<reason>` prose itself is a clickable OSC 8 terminal hyperlink to the rule's `ref` — so `git push --force: overwrites shared remote history` links to the docs, with the verbose URL dropped from the line. The rule-set name is omitted; the `ref` link supplies that context. Set `CLAUDEWATCH_HYPERLINKS` to `off` (also `0`/`false`/`none`/empty) to keep the plain `— <url>` form — for terminals without OSC 8 support or anyone who prefers the bare link. The decision log still records the canonical plain reason, so `/ClaudeWatch:learn` reads the same text as before (see `SPEC.md` `[OUT-02]`, `[OUT-06]`).

### Other
- New `tests/test-output.sh` covers the prose hyperlinking, the `CLAUDEWATCH_HYPERLINKS` opt-out, no-ref rules, and the plain-log guarantee.

## 0.12.0

### Features
- **`/ClaudeWatch:learn` reports its window and can reset the log.** The analysis now leads with how much history backs it — record count, distinct sessions, and the span from oldest to newest decision (`meta.distinct_sessions`, `meta.oldest_ts`/`newest_ts`, `meta.span_days`) — so thin windows are visible rather than implied. After changes are applied, the skill offers to reset the log via the new `scripts/reset-decisions.py`, which **archives** the current log to `~/.claude/claudewatch/archive/` by default (recoverable, matching the "block is for no-recovery" ethos) or deletes it with `--hard`. Resetting starts the next pass from the post-change baseline instead of re-surfacing commands you just dispositioned (see `SPEC.md` `[SK-18]`–`[SK-19]`).

### Other
- `tests/test-analyze.sh` asserts the window fields; new `tests/test-reset-decisions.sh` covers archive, `--hard`, logging-disabled, and missing-log paths. `reset-decisions.py` resolves the log path the same way the engine does.

## 0.11.0

### Features
- **`watch-git` no longer asks on stage manipulation.** The `git add`, `git rm`, `git rm --cached`, and non-hard `git reset` ask rules are removed — staging is recoverable (unstage, re-add, restore from HEAD), so prompting on it is noise on top of the commit prompt. `git reset --hard` keeps its ask: it discards uncommitted working-tree changes, which is beyond stage manipulation. Block rules and the remaining ask rules (`commit`, `stash`, `push`, `--force-with-lease`) are unchanged (see `SPEC.md` `[SH-01]`).

## 0.10.0

### Features
- **Decision logging is on by default.** The engine now writes `~/.claude/claudewatch/decisions.jsonl` with no setup, so `/ClaudeWatch:learn` has data to work from the first time you reach for it. `CLAUDEWATCH_LOG` shifts from an enable switch to an override: set it to a path to log elsewhere, or to `off` (also `0`/`false`/`none`/empty, case-insensitive) to opt out. Disabling it also disables `/ClaudeWatch:learn`, which has nothing to read without the log — the skill now warns loudly when it detects the opt-out, and distinguishes that from the on-but-no-records-yet case (see `SPEC.md` `[LOG-01]`–`[LOG-02]`, `[SK-13]`).

### Other
- The test harness sets `CLAUDEWATCH_LOG=off` for the suite so rule tests don't append to the real user log; `tests/test-logging.sh` covers default-on-when-unset and the opt-out values, and `tests/test-analyze.sh` covers the disabled-logging guidance. `scripts/analyze-decisions.py` resolves the log path the same way the engine does and reports the disabled vs. no-records-yet states distinctly.

## 0.9.0

### Features
- **Decision logging + `/ClaudeWatch:learn`.** Setting `CLAUDEWATCH_LOG` makes the engine append each decision (command, decision, matched rule reasons, timestamp, session, cwd) to a JSONL log. The new `/ClaudeWatch:learn` skill aggregates that log via `scripts/analyze-decisions.py` (read-only, stdlib-only) into a batch of proposed permission changes — promote frequently-allowed commands to your allow list, add `except` clauses to noisy ask rules, and surface blocks that may be in your way — so accumulated prompts are vetted once rather than per command. It works from the hook's own decisions (allowed / asked / blocked) rather than heuristically scanning transcripts. Logging is an opt-in side channel that does not affect the decision (see `SPEC.md` `[LOG-01]`–`[LOG-04]`, `[SK-13]`–`[SK-17]`).
- Each record also captures the active `permission_mode`. Since the `PreToolUse` hook runs before the permission-mode check, ClaudeWatch's `deny`/`ask` still take effect under `auto` mode — and `/ClaudeWatch:learn` reports `by_mode` and a per-candidate `auto_executed` count, so under auto mode it doubles as an audit of what ran unattended.

### Other
- `SPEC.md`: new `LOG` category and `[LOG-01]`–`[LOG-04]`; `/ClaudeWatch:learn` recorded in `[SK-13]`–`[SK-17]`. `AGENTS.md` clarifies the determinism contract covers the decision, with logging confined to `_log_event`. Engine logging is exercised by `tests/test-logging.sh`; the analyzer by `tests/test-analyze.sh`.

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
