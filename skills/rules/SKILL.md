---
name: rules
description: >
  View ClaudeWatch's rules and change how they apply to you: move a rule between
  block and ask, turn a rule or a whole rule set off, or restore the shipped
  tier, kept in an overrides file that survives plugin upgrades.
disable-model-invocation: true
---

ClaudeWatch ships its rules in `watches/watch-*.yml`, inside the plugin's
install folder, which every upgrade replaces. A user's changes live in
`~/.claude/claudewatch/overrides.yml` instead, and `scripts/overrides.py` is the
only program that writes it. This skill lists the rules as they apply now and
walks each change through a preview before writing.

An override can move a shipped rule between `block` and `ask`, turn a rule or a
whole rule set `off`, or restore the shipped tier. It cannot add a rule, a
pattern, or an exemption; a new rule belongs in the plugin's source.

## Steps

### 1. Find the plugin root

The commands below run `${CLAUDE_PLUGIN_ROOT}/scripts/overrides.py`. If
`${CLAUDE_PLUGIN_ROOT}` is empty, stop and report: do not guess a path.

### 2. Read the rules as they apply now

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/overrides.py" show --json
```

It reports each shipped rule set with `off` (the whole set is turned off), and
each rule with its `shipped` and `effective` tier and its `reason`, plus a
`stale` list: overrides naming a rule set or rule the shipped rules no longer
have, which the engine ignores. If it exits non-zero, the overrides file is
malformed and **every screened call is being denied**: show the error, offer
`reset` (step 4) or a hand fix, and stop until it loads.

### 3. Display

For each rule set, present two tables of its **effective** rules. Number IDs in
shipped order, `<short-name>-block-NN` / `<short-name>-ask-NN`, where the short
name drops `watch-` (`watch-git` -> `git`) and NN is zero-padded. Mark a rule
whose effective tier differs from its shipped one with its shipped tier
(`was ask`), and list a rule turned off under its set as `off (was block)`.

**watch-git**

**🚫 block** — rejected outright:

| id | command | reason |
|----|---------|--------|
| git-block-01 | `git push --force` | reason |
| git-block-07 | `git commit` *(was ask)* | reason |

**❓ ask** — require confirmation:

| id | command | reason |
|----|---------|--------|
| git-ask-01 | `git checkout -- <file>` | reason |

Off: `git stash` *(was ask)*

Then list any rule set turned off (`watch-dotnet` — off), and any stale
override with a note that it is ignored and can be removed with `reset`.

If the user passed `--list`, stop here.

### 4. Prompt for edits

Ask: **"Make any changes? (Enter a command or press Enter to skip)"**

```
Commands:
  <id>:block    — move the rule to block        (e.g. git-ask-02:block)
  <id>:ask      — move the rule to ask          (e.g. git-block-03:ask)
  <id>:off      — turn the rule off             (e.g. installs-ask-05:off)
  <id>:reset    — restore the rule's shipped tier
  off <name>    — turn a rule set off           (e.g. off watch-dotnet)
  on <name>     — restore a rule set            (e.g. on watch-dotnet)
  reset         — remove every override
  done / ↵      — finish
>
```

Accept one command per turn and loop until `done` or an empty reply. Hold the
changes; nothing is written yet. If the user makes no changes, stop.

A rule moved from ask to block keeps its exemptions: `rm -rf` moved to block
still skips the in-tree and scratch-path deletes it used to skip, and blocks
what it used to ask about. Say so when the user moves a rule that has one.

### 5. Preview

Show the affected rule tables as they will be after the changes, each change
marked, then ask:

```
Confirm changes? [yes / edit / abort]
```

- **yes** — apply.
- **edit** — return to step 4.
- **abort** — discard the pending changes.

Turning a block rule off or down to ask removes a refusal ClaudeWatch ships
with. Name each one in the preview so the confirmation covers it.

### 6. Apply

Run one command per change, by the rule's set name and its `name` exactly as
`show` reported it:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/overrides.py" set <set> "<rule name>" <ask|block|off>
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/overrides.py" set <set> off
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/overrides.py" reset <set> ["<rule name>"]
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/overrides.py" reset
```

`<id>:reset` and `on <name>` are `reset`; setting a rule to its shipped tier
also removes its entry. Never edit `watches/` or the overrides file by hand from
this skill.

### 7. Verify

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/overrides.py" check
```

A malformed overrides file denies every screened call, so report any error at
once. Then summarize what changed. The changes apply to the next command;
from the next session on, each session's start logs them to the decision log,
so they stay visible.
