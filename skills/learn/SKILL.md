---
name: learn
description: >
  Analyze the ClaudeWatch decision log to find the rules that ask most and the
  blocks that get in the way, and propose overrides (move a rule between ask and
  block, or turn it off) reviewed as one batch, then reset the log.
disable-model-invocation: true
---

# ClaudeWatch — learn

ClaudeWatch watches every command and records its decision; this skill is the
*learn* step that turns those recordings into suggestions. You vet a window's
worth of accumulated prompts once, as a batch, instead of pressing enter on
each one. It is the replacement for the generic transcript-scanning approach:
it works from the hook's own decisions, so it knows what ClaudeWatch allowed,
asked, and blocked — not just what looked read-only.

## 0. Prerequisite: a decision log to learn from

Logging is **on by default** — the hook writes to
`~/.claude/claudewatch/decisions.jsonl` unless `CLAUDEWATCH_LOG` is set to an
opt-out value (`off`, `0`, `false`, `none`, or empty). Each `Bash` record stores
the command *shape* (`git push`, not the full command with its arguments), never
the raw command, so inline secrets stay out of the plaintext log; the file is
owner-only (`0600`). Two states block a learn pass; distinguish them before doing
anything else.

First, check whether logging has been turned off:

```bash
echo "CLAUDEWATCH_LOG=[${CLAUDEWATCH_LOG:-<unset>}]"
```

- **`off` / `0` / `false` / `none` / empty** — logging is **disabled**. Warn the
  user **loudly** that disabling logging disables this skill: `/ClaudeWatch:learn`
  has no data to work from and stays useless until logging is re-enabled. To
  re-enable, remove the opt-out from the `env` block in their `settings.json`
  (unset it, or set it back to the default path) and restart their sessions:

  ```json
  { "env": { "CLAUDEWATCH_LOG": "~/.claude/claudewatch/decisions.jsonl" } }
  ```

  Then stop — there is nothing to learn from until logging is back on and
  sessions have run.

Otherwise logging is on; check whether the log has any records yet:

```bash
ls -la "${CLAUDEWATCH_LOG:-$HOME/.claude/claudewatch/decisions.jsonl}"
```

If the file does not exist, logging is on but no sessions have run with the hook
active yet. Tell the user to run some sessions, then stop — there is nothing to
learn from until then.

## 1. Run the analyzer

Forward any window argument the user passed (`--since 1d`, `--since 4h`). The
analyzer is read-only and emits JSON:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/analyze-decisions.py" --since 1d
```

Useful flags: `--min-count N` (default 3) sets how many times a command must
recur before it is proposed; `--log PATH` reads a different log.

## 2. Present the two buckets

Open with the window the proposals are drawn from, so the user can weigh how
much history backs them. Read it from `meta`: `records_considered`,
`distinct_sessions`, and `span_days` (plus `oldest_ts`/`newest_ts`). State it in
one line — e.g. *"Based on 1,650 decisions across 23 sessions over 2.1 days
(2026-06-01 → 2026-06-03)."* A short span or few sessions means the suggestions
are thin; say so.

Then render the JSON as two tables. ClaudeWatch's own decisions are only ever
`ask` or `deny`; what it lets through is Claude Code's to decide, so the log's
allowed records feed `by_mode` and the window, never a proposal.

- **Ask candidates** — commands ClaudeWatch repeatedly *asks* about. Columns:
  shape, count, the matched rule(s). For each, the choice is: move the rule to
  `block` if it guards something unrecoverable, turn it `off` if every prompt
  it raised was approved and the user doesn't want it, or leave it. A high
  count under `auto` is *not* evidence the prompt is doing its job — see "Auto
  mode" below for why an `ask` record can't tell you whether anyone saw it.
- **Deny summary** — commands ClaudeWatch *blocked*, grouped by reason. A high
  count means a workflow the user needs is blocked. The choice is: move the rule
  to `ask`, turn it `off`, or leave it. Default to leaving it; a block is there
  because what it guards has no recovery.

## 3. Apply the approved items as overrides

Ask which items to apply, one decision per item. Each one becomes an override
in `~/.claude/claudewatch/overrides.yml`, written by the same program
`/ClaudeWatch:rules` uses, so it survives a plugin upgrade and never touches the
shipped rules.

A `matched` entry is `<rule name>: <reason> — <ref>`, without the rule set. Find
the set in `show --json`: the rule whose `name` and `reason` both match. Rule
names repeat across sets (`eval (bash)` is in three), so match the reason too.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/overrides.py" show --json
```

Before writing, list each change as `<set> / <rule>: <shipped tier> -> <new
tier>` and get an explicit `yes`. Name every block being lowered to ask or
turned off, since that removes a refusal ClaudeWatch ships with. Then:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/overrides.py" set <set> "<rule name>" <ask|block|off>
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/overrides.py" check
```

A deny-summary rule changes only when the user approves that item.

## 4. Changes the overrides can't make

An override can't add an `except` for one safe variant of a command; it moves
or drops the whole rule. When the better fix is narrower than that (stop asking
about `rm -rf ./build` but keep asking about other deletes), say so and point
the user at the plugin's issue tracker rather than turning the rule off.

## 5. Offer to reset the log

Once the approved changes are applied, offer to reset the decision log. This is
the *adjust, then reset* loop: after you change a rule, the accumulated history
keeps re-surfacing those same commands on the next pass. Resetting starts the next window from the post-change baseline,
so the next learn measures only what the new configuration still prompts on.

Reset **archives** by default — it moves the log to
`~/.claude/claudewatch/archive/decisions-<timestamp>.jsonl`, so prior history is
recoverable — and reports what it cleared:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/reset-decisions.py"
```

Pass `--hard` to delete the log outright instead of archiving it. Only offer
reset after changes are applied — a reset before the user has decided what to
do with the buckets throws away the very data this pass is built on. If the
user applied nothing, leave the log alone.

## Auto mode

A `deny` from ClaudeWatch blocks in every permission mode, because the hook runs
before the mode is checked. An `ask` prompts only in a prompting mode. In `auto`
the command runs without a prompt
([claude-code#89561](https://github.com/anthropics/claude-code/issues/89561)),
and in a headless `--print` run it is denied, since nobody can answer. An
interactive session with no permission mode configured starts in `auto`.

Claude Code 2.1.319 adds two more outcomes, per its changelog:

- **`permissions.denyInsteadOfPrompting` denies the `ask`** in every mode,
  interactive sessions, subagents and teammates included, and the turn
  continues.
- **`auto` runs the `ask` unprompted only where the auto-mode server check is
  reachable.** With telemetry or feature flags off (including behind LLM
  gateways), calls the server can't check are asked about or denied, unless
  `CLAUDE_CODE_AUTO_MODE_SERVER=0` keeps the built-in classifier.

**An `ask` record means the engine asked, not that a person answered.** The log
can't tell the outcomes apart: `permission_mode` reads `auto` whether or not a
prompt was shown, `--permission-prompts none` sets no field of its own, and
`denyInsteadOfPrompting` leaves the mode as configured. Read `by_mode` as how
often a command ran, not how often someone reviewed it.

**When most records in `by_mode` are `auto`, report an audit instead.** The user
saw few of the prompts this skill normally tunes, so what's worth their time is
what ran unattended:

- Lead with the ask candidates ("these asked N times, none necessarily
  reviewed: keep asking, or promote to block?").
- Present the deny summary as what the block tier caught while nobody was
  watching.
- Tell the user their sessions run in `auto`, and that setting
  `"permissions": { "defaultMode": "default" }` makes the ask tier prompt again.

## Notes

- `command_shape` groups by program plus its leading subcommand tokens, so
  `git push` and `git commit` are distinct candidates. An override acts on the
  matched rule, though, so overriding the rule behind one shape changes every
  command that rule matches.
