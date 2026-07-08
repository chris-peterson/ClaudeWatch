---
name: mutes
description: >
  List the ClaudeWatch rule sets and ask rules muted for this session. Use when
  the user asks "what's muted?", "show mutes", or "list session mutes".
---

# ClaudeWatch — mutes

Show which rule sets and ask rules are silenced for this session, and the exact
ask prompts each one covers.

## Steps

1. **List the active mutes:**

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/mute.py" --watches "${CLAUDE_PLUGIN_ROOT}/watches" --session "${CLAUDE_SESSION_ID}" list
   ```

2. **Relay the output.** If nothing is muted, say so. Otherwise present the muted
   tokens and the ask prompts they silence, and mention `/ClaudeWatch:unmute
   <name>` to clear one.

## Related

- `/ClaudeWatch:mute <name>` — mute a rule set or ask rule for the session.
- `/ClaudeWatch:unmute <name>` — clear a mute.
