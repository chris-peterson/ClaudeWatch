---
description: >
  Configure git-guardian rules. Reads the current block/ask rules from rules.yml,
  presents them to the user, and guides additions and changes. Invoke when setting up
  git-guardian for the first time or adjusting rules.
---

Configure git-guardian rules interactively.

## Steps

1. **Find the plugin root**: run `bash -c 'echo "${CLAUDE_PLUGIN_ROOT}"'`. If the
   output is empty, use the current working directory as the plugin root.

2. **Read and display** `$PLUGIN_ROOT/rules.yml`. Present rules in two tables.
   Prefix IDs with `b` (block) and `a` (ask):

   **block** — rejected outright:
   | id | rule | ref |
   |----|------|-----|
   | b1 | `pattern` (reason) | ... |

   **ask** — require confirmation:
   | id | rule | ref |
   |----|------|-----|
   | a1 | `pattern` (reason) | ... |

3. **Prompt**:

   ```
   Enter a command:
     <id>:block   — move rule to block (e.g. a2:block)
     <id>:ask     — move rule to ask   (e.g. b3:ask)
     <id>:allow   — remove rule; command passes through unchecked (e.g. a5:allow)
     add          — add a new rule
     done         — save and exit
   >
   ```

   For `add`: prompt for the git command to match, reason, and optional `ref`
   (git docs URL). Ask whether it should block or ask. Derive the Python regex
   `pattern` from the command description, following the style of existing patterns.

   Accept multiple commands per turn. Loop back to the prompt after each operation
   until the user enters `done`.

4. **Apply** each change to `rules.yml`. Each rule must have `pattern`, `reason`, and
   `ref` fields. Preserve the exact YAML format:
   ```yaml
       - pattern: 'regex'
         reason: short description of team impact
         ref: https://...
   ```

5. **Verify**: run `bash $PLUGIN_ROOT/tests/test-git-guard.sh`. If tests fail, explain
   which rule caused the failure and offer to fix or revert.

   If any rules were added, note that `$PLUGIN_ROOT/tests/test-git-guard.sh` has no
   coverage for them yet and offer to add test cases.

6. **Mark configured**: `touch ~/.claude/.git-guardian-configured`

7. **Confirm** what changed.

If the user passes `$ARGUMENTS` containing `--list`, only display the current rules
without entering the edit loop.
