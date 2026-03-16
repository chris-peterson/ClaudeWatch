---
description: >
  Add or change a single git-guardian rule in one command.
  Usage: /git-guardian:guard <block|ask|allow> '<git command>'
  Examples:
    /git-guardian:guard block 'add .'
    /git-guardian:guard ask 'tag'
    /git-guardian:guard allow 'stash'
---

Make a targeted change to a single git-guardian rule.

`$ARGUMENTS` has the form: `<action> '<git command>'`

- **action**: `block`, `ask`, or `allow`
- **git command**: a description like `add .`, `tag`, `stash pop`, `rebase -i`

## Steps

1. **Find the plugin root**: `bash -c 'echo "${CLAUDE_PLUGIN_ROOT}"'`. Fall back to
   the current working directory if empty.

2. **Read** `$PLUGIN_ROOT/rules.yml`.

3. **Check for a matching rule** by scanning existing patterns against the described
   command (try running the command string against each pattern).

   - **Match found — action changes its disposition** (e.g., moving ask → block, or
     removing via allow): present the current rule and the proposed change. Ask for
     confirmation before proceeding.

   - **Match found — action matches current disposition** (e.g., `block 'push --force'`
     when a block rule already covers it): inform the user, show the existing rule, and
     ask if they want to edit the reason or pattern instead.

   - **No match — action is `block` or `ask`**: infer a reason that explains the
     team-workflow impact, in the same tone as existing reasons in `rules.yml`
     (e.g., "don't add all at once; require specific paths"). Derive a Python regex
     `pattern` following the style of existing patterns. Suggest a `ref` from the git
     docs. Present the full proposed rule and ask the user to confirm or adjust before
     writing.

   - **No match — action is `allow`**: tell the user no rule exists for that command;
     it already passes through.

4. **Apply** the confirmed change to `rules.yml`:
   - `block` → add to or move into the `deny` section
   - `ask` → add to or move into the `ask` section
   - `allow` → remove the matching rule

5. **Verify**: `bash $PLUGIN_ROOT/tests/test-git-guard.sh`. If tests fail, explain
   which rule caused it and offer to fix or revert.

   If a rule was added, offer to add a test case to
   `$PLUGIN_ROOT/tests/test-git-guard.sh`.

6. **Confirm** the change in one line, e.g.:
   `✓ block: add . — don't add all at once; require specific paths`
