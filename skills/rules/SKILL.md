---
description: >
  View and edit ClaudeWatch rules. Displays the current block/ask rules
  for each rule set as tables, then guides the user through any changes with
  conflict detection and a preview before writing. Invoke with no arguments
  to list and optionally edit; pass --list to list only.
---

View and interactively edit ClaudeWatch watches & rules.

## Steps

### 1. Find the plugin root

Run `bash -c 'echo "${CLAUDE_PLUGIN_ROOT}"'`. If the output is empty, use the
current working directory.

### 2. Discover rule sets

List YAML files in `$PLUGIN_ROOT/rules/`. Each file is a rule set
(e.g. `watch-git.yml`, `watch-installs.yml`).

Also check for disabled rule sets — files ending in `.yml.disabled` in the
same directory. These are rule sets that have been toggled off.

### 3. Read and display rules for each rule set

For each **enabled** rule set, present rules in two tables. Use the rule set
`name` field as the heading. Use the naming convention
`<ruleset>-block-NN` / `<ruleset>-ask-NN` for IDs, where `<ruleset>` is the
short name from the YAML `name` field (e.g. `watch-git` → `git`), and NN is
zero-padded (e.g. `git-block-01`, `installs-ask-03`):

**watch-git** (`rules/watch-git.yml`)

**🚫 block** — rejected outright:

| id | command | reason |
|----|---------|--------|
| git-block-01 | `name` | reason |

**❓ ask** — require confirmation:

| id | command | reason |
|----|---------|--------|
| git-ask-01 | `name` | reason |

After listing all enabled rule sets, if any **disabled** rule sets exist, list
them:

**Disabled rule sets:**
- `watch-foo` (`rules/watch-foo.yml.disabled`)

### 4. Check for `--list` flag

If `$ARGUMENTS` contains `--list`, stop here and do not enter the edit loop.

### 5. Prompt for edits

Ask: **"Make any changes? (Enter a command or press Enter to skip)"**

```
Commands:
  <id>:block      — move rule to block       (e.g. git-ask-02:block)
  <id>:ask        — move rule to ask          (e.g. git-block-03:ask)
  <id>:allow      — remove rule entirely      (e.g. installs-ask-05:allow)
  add             — add a new rule
  disable <name>  — disable an entire rule set (e.g. disable watch-files)
  enable <name>   — re-enable a disabled rule set (e.g. enable watch-files)
  new             — create a new custom rule set
  done / ↵        — finish
>
```

For `add`: prompt for (1) the command to match, (2) which rule set it belongs
to, (3) a reason (why the rule exists), (4) an optional `ref` (docs URL), and
(5) whether it should block or ask. Derive a Python `re.search()` regex from
the command description, following the style of existing patterns.

For `disable <name>`: rename `rules/<name>.yml` to `rules/<name>.yml.disabled`.
The engine only loads `*.yml` files, so this effectively turns off the rule set
without deleting it.

For `enable <name>`: rename `rules/<name>.yml.disabled` back to
`rules/<name>.yml`.

For `new`: guide the user through creating a custom rule set:

1. **Name** — the rule set name (e.g. `watch-docker`). Must start with `watch-`.
2. **Filter** — a regex pre-check to skip irrelevant commands (e.g. `\bdocker\b`).
   Explain: "This is a fast regex that skips commands that can't possibly match
   any of your rules. Use `\b` word boundaries around keywords."
3. **Rules** — prompt for one or more rules, each with:
   - `name` — friendly label (e.g. `docker run --privileged`)
   - `pattern` — Python `re.search()` regex
   - `reason` — why the rule exists
   - `ref` — optional docs URL
   - `block` or `ask`
4. Write the file to `rules/watch-<name>.yml` using the standard YAML format.

Accept one command per turn. Loop back to the prompt after each operation
until the user enters `done` or presses Enter with no input.

If the user presses Enter immediately (no changes requested), skip to step 8.

### 6. Conflict and duplicate check

Before writing, scan the updated rule list for:

- **Exact duplicates** — identical `pattern` strings.
- **Shadowing** — one pattern is a strict substring of another and would match
  a superset of commands (e.g., `git\s+push` shadows `git\s+push\s+origin`).
- **Cross-section conflicts** — same effective pattern appears in both `block`
  and `ask`.

Report any findings and ask the user how to resolve them before continuing.

### 7. Preview

Show the full updated rule tables (same format as step 3) so the user can
review the final state. Then ask:

```
Confirm changes? [yes / edit / abort]
```

- **yes** — proceed to write.
- **edit** — return to the prompt in step 5.
- **abort** — discard all pending changes and exit.

### 8. Apply changes

Write only the modified rule set files. Preserve the exact YAML format:

```yaml
name: watch-name
filter: 'regex'

rules:
  block:
    - name: command name
      pattern: 'regex'
      reason: why the rule exists
      ref: https://...

  ask:
    - name: command name
      pattern: 'regex'
      reason: why the rule exists
      ref: https://...
```

### 9. Verify

Run `bash $PLUGIN_ROOT/tests/test-watchdog.sh`. If tests fail, explain which
rule caused the failure and offer to fix or revert.

If any rules were added, note that the test file has no coverage for them yet
and offer to add test cases.

### 10. Confirm

Summarize what changed (or confirm no changes were made).
