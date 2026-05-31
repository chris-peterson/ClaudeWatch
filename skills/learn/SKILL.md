---
description: >
  Learn from the ClaudeWatch decision log and propose permission changes that
  cut prompt fatigue — promote frequently-allowed commands to your allow list,
  add `except` clauses to noisy ask rules, and surface blocks that may be in
  your way. Invoke with /ClaudeWatch:learn, optionally with a window like
  `--since 1d`. Triggers on "what keeps prompting me", "tune my watches",
  "reduce prompts", "learn from my sessions".
---

# ClaudeWatch — learn

ClaudeWatch watches every command and records its decision; this skill is the
*learn* step that turns those recordings into suggestions. You vet a window's
worth of accumulated prompts once, as a batch, instead of pressing enter on
each one. It is the replacement for the generic transcript-scanning approach:
it works from the hook's own decisions, so it knows what ClaudeWatch allowed,
asked, and blocked — not just what looked read-only.

## 0. Prerequisite: logging must be on

The hook only records when `CLAUDEWATCH_LOG` is set in its environment. Check
whether a log exists:

```bash
ls -la "${CLAUDEWATCH_LOG:-$HOME/.claude/claudewatch/decisions.jsonl}"
```

If it does not exist, logging is off. Tell the user to add an `env` block to
the ClaudeWatch hook environment (user `settings.json`) and restart their
sessions:

```json
{ "env": { "CLAUDEWATCH_LOG": "~/.claude/claudewatch/decisions.jsonl" } }
```

Then stop — there is nothing to learn from until sessions have run with logging
on.

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

Render the JSON as three tables. Lead with the one that removes the most
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
