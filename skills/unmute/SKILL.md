---
name: unmute
description: >
  Clear a ClaudeWatch session mute so its confirmation prompts return. Use when
  the user says "unmute", "re-enable prompts for <X>", or "stop muting <X>".
---

# ClaudeWatch — unmute

Clear a mute set earlier this session with `/ClaudeWatch:mute`, so that rule set
or ask rule prompts again for the rest of the session.

## Steps

1. **Resolve the target** the same way `/ClaudeWatch:mute` does — a rule-set name
   (`git` / `watch-git`) or an ask rule name (`git commit`). Run
   `/ClaudeWatch:mutes` first if you're unsure what's currently muted.

2. **Clear the mute:**

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/mute.py" --watches "${CLAUDE_PLUGIN_ROOT}/watches" --session "${CLAUDE_SESSION_ID}" remove <name> [<name>...]
   ```

3. **Relay the CLI's output** — it confirms what was unmuted and what mutes, if
   any, remain.

## Related

- `/ClaudeWatch:mute <name>` — mute a rule set or ask rule for the session.
- `/ClaudeWatch:mutes` — list this session's active mutes.
