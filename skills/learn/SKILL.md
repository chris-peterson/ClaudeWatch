---
description: >
  Learn from the ClaudeWatch decision log and propose permission changes that
  cut prompt fatigue. Triggers on "what keeps prompting me", "reduce prompts".
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
recur before it is proposed; `--settings PATH` points at a different
`settings.json`; `--log PATH` reads a different log.

## 2. Present the three buckets

Open with the window the proposals are drawn from, so the user can weigh how
much history backs them. Read it from `meta`: `records_considered`,
`distinct_sessions`, and `span_days` (plus `oldest_ts`/`newest_ts`). State it in
one line — e.g. *"Based on 1,650 decisions across 23 sessions over 2.1 days
(2026-06-01 → 2026-06-03)."* A short span or few sessions means the suggestions
are thin; say so.

Then render the JSON as three tables. Lead with the one that removes the most
prompts.

- **Allow candidates** — commands ClaudeWatch already allows that are *not*
  covered by your allow list, so Claude Code prompts on them. Columns: shape,
  count, distinct dirs, suggested `allow` pattern. These are the prompt-fatigue
  wins.
- **Ask candidates** — commands ClaudeWatch repeatedly *asks* about. Columns:
  shape, count, the matched rule(s). For each, the choice is: add an `except`
  for a demonstrably-safe variant, or leave it (the prompt is doing its job).
- **Deny summary** — commands ClaudeWatch *blocked*, grouped by reason.
  Informational. A high count means a workflow you need is blocked — worth a
  conversation, never an automatic change.

## 3. Let the user choose, then confirm

Ask which items to apply. For the **allow candidates**, confirm the scope:

- **User** (`~/.claude/settings.json`) — applies to every session.
- **Project** (`.claude/settings.json` in the repo) — applies to that repo only.

Each suggested pattern is conservative (as narrow as the commands actually
run). Offer to widen or narrow any pattern before writing. Before writing,
show the exact `permissions.allow` additions and get an explicit `yes`.

Apply by reading the chosen `settings.json`, appending the approved patterns to
`permissions.allow` (creating the keys if absent, de-duplicating), and writing
it back. Do not reorder or drop existing entries.

> If the user keeps their `settings.json` under external management (synced from
> another source rather than hand-edited), do not edit `~/.claude/settings.json`
> directly — show them the patches to apply at their source instead.

## 4. Ask candidates → rule changes

For approved **ask candidates**, the change is an `except` on the matched rule
(to stop prompting on a safe variant) — that is a rule edit, so route it
through `/ClaudeWatch:rules`, which validates and previews. Name the rule (the
`matched` reason identifies the set) and the `except` regex to add. Do not
hand-edit shipped rule YAML from this skill.

## 5. Deny summary → never automatic

Surface blocked-command counts so the user sees what is in their way, but make
no change. If a block is genuinely unwanted, that is a deliberate rule decision
for `/ClaudeWatch:rules` (demote block → ask) or a spec discussion — not a
side effect of a learn pass. A frequently-allowed but consequential command in
the *allow* bucket (e.g. `terraform apply`) is the inverse signal: a coverage
gap where a new ask rule may belong.

## 6. Offer to reset the log

Once the approved changes are applied, offer to reset the decision log. This is
the *adjust, then reset* loop: after you promote commands to the allow list or
change a rule, the accumulated history keeps re-surfacing those same commands on
the next pass. Resetting starts the next window from the post-change baseline,
so the next learn measures only what the new configuration still prompts on.

Reset **archives** by default — it moves the log to
`~/.claude/claudewatch/archive/decisions-<timestamp>.jsonl`, so prior history is
recoverable — and reports what it cleared:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/reset-decisions.py"
```

Pass `--hard` to delete the log outright instead of archiving it. Only offer
reset after changes are applied — a reset before the user has dispositioned the
buckets throws away the very data this pass is built on. If the user applied
nothing, leave the log alone.

## Auto mode

ClaudeWatch's `PreToolUse` hook runs *before* the permission-mode check, so its
`deny` still blocks and `ask` still prompts even under `auto` or
`bypassPermissions`. Each record carries the active `mode`, and the analyzer
reports `by_mode` plus an `auto_executed` count per allow candidate. Under auto
mode the prompts are already gone, so this skill's value shifts from *cutting
prompts* to *auditing what ran unattended*: lead with the high-`auto_executed`
allow candidates ("these ran N times with no review — keep allowing, or add a
watch rule?") and treat the deny summary as the record of what the hard backstop
caught while you weren't watching.

## Notes

- The analyzer's allow-list match is an approximate prefix check; Claude Code's
  own matcher is the source of truth. Its only job is to avoid re-proposing
  commands you already allow.
- `command_shape` groups by program plus its leading subcommand tokens, so
  `gh pr view` and `gh pr merge` are distinct candidates — promoting one does
  not silently allow the other.
