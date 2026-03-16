---
description: >
  View and edit git-guardian rules. Displays the current block/ask rules as a
  table, then guides the user through any changes with conflict detection and
  a preview before writing. Invoke with no arguments to list and optionally
  edit; pass --list to list only.
---

View and interactively edit git-guardian rules.

## Steps

### 1. Find the plugin root

Run `bash -c 'echo "${CLAUDE_PLUGIN_ROOT}"'`. If the output is empty, use the
current working directory.

### 2. Read and display `$PLUGIN_ROOT/rules.yml`

Present rules in two tables. Use 🚫 for block rules and ❓ for ask rules.
Prefix IDs with `b` (block) and `a` (ask):

**🚫 block** — rejected outright:

| id | command | reason |
|----|---------|--------|
| b1 | `name` | reason |

**❓ ask** — require confirmation:

| id | command | reason |
|----|---------|--------|
| a1 | `name` | reason |

### 3. Check for `--list` flag

If `$ARGUMENTS` contains `--list`, stop here and do not enter the edit loop.

### 4. Prompt for edits

Ask: **"Make any changes? (Enter a command or press Enter to skip)"**

```
Commands:
  <id>:block   — move rule to block    (e.g. a2:block)
  <id>:ask     — move rule to ask      (e.g. b3:ask)
  <id>:allow   — remove rule entirely  (e.g. a5:allow)
  add          — add a new rule
  done / ↵     — finish
>
```

For `add`: prompt for (1) the git command to match, (2) a reason (why the rule
exists), (3) an optional `ref` (git docs URL), and (4) whether it should block
or ask. Derive a Python `re.search()` regex from the command description,
following the style of existing patterns in `rules.yml`.

Accept one command per turn. Loop back to the prompt after each operation
until the user enters `done` or presses Enter with no input.

If the user presses Enter immediately (no changes requested), skip to step 7.

### 5. Conflict and duplicate check

Before writing, scan the updated rule list for:

- **Exact duplicates** — identical `pattern` strings.
- **Shadowing** — one pattern is a strict substring of another and would match
  a superset of commands (e.g., `git\s+push` shadows `git\s+push\s+origin`).
- **Cross-section conflicts** — same effective pattern appears in both `block`
  and `ask`.

Report any findings and ask the user how to resolve them before continuing.

### 6. Preview

Show the full updated rule tables (same format as step 2) so the user can
review the final state. Then ask:

```
Confirm changes? [yes / edit / abort]
```

- **yes** — proceed to write.
- **edit** — return to the prompt in step 4.
- **abort** — discard all pending changes and exit.

### 7. Apply changes to `rules.yml`

Write only if changes were made. Preserve the exact YAML format:

```yaml
    - pattern: 'regex'
      reason: why the rule exists
      ref: https://...
```

### 8. Verify

Run `bash $PLUGIN_ROOT/tests/test-git-guard.sh`. If tests fail, explain which
rule caused the failure and offer to fix or revert.

If any rules were added, note that the test file has no coverage for them yet
and offer to add test cases.

### 9. Confirm

Summarize what changed (or confirm no changes were made).
