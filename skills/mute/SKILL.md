---
name: mute
description: >
  Silence a ClaudeWatch rule set's or ask rule's confirmation prompts for the
  rest of this session — for when a chatty recipe keeps prompting on recoverable
  ops (commit, amend, stash) and you want to review at the end. Use when the user
  says "mute", "stop asking me about <X> this session", "let it run without
  prompting on <X>", or similar. Silences ask rules only; block rules still fire.
---

# ClaudeWatch — mute

A **session mute** silences a rule set's or an individual ask rule's prompts for
the duration of this Claude Code session. It suppresses **ask** rules only —
**block** rules (e.g. `git push --force`) always fire, so muting is safe for the
"let the agent run wild, review at the end" workflow: only the *recoverable*
prompts go quiet.

Mutes are per-session and clear themselves when the session ends.

## What can be muted

- **A whole rule set** — its short name (`git`) or full name (`watch-git`). Mutes
  every ask rule in the set.
- **A single ask rule** — its name, the label the ask prompt shows (e.g.
  `git commit`). Pass a name with spaces as a single quoted argument.

Block rules can't be muted; asking to mute one (or a set with no ask rules) is
reported as a no-op.

## Steps

1. **Resolve the target from the request.** If the user named a rule set or id
   directly, use it. For natural language ("stop asking me about commits"), map
   it to the narrowest matching token — prefer a specific ask rule over the whole
   set when the intent is specific. If you're unsure which rule they mean, run
   `/ClaudeWatch:rules --list` to see the rule names, then pick.

2. **Apply the mute** by running the CLI, passing the active session id (Claude
   Code expands `${CLAUDE_SESSION_ID}` for you):

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/mute.py" --watches "${CLAUDE_PLUGIN_ROOT}/watches" --session "${CLAUDE_SESSION_ID}" add <name> [<name>...]
   ```

   Pass a multi-word rule name as a single quoted argument (`"git commit"`).

3. **Relay the CLI's output verbatim** — it names exactly which ask prompts are
   now silenced and how to clear them (`/ClaudeWatch:unmute <name>`). Don't
   summarize it away; the explicit list is the point ([MUTE-06]).

If the CLI reports it could not resolve the active session, the
`${CLAUDE_SESSION_ID}` placeholder did not expand — run the command from this
skill rather than pasting it by hand, so Claude Code substitutes the real id.

## Related

- `/ClaudeWatch:unmute <name>` — clear a mute.
- `/ClaudeWatch:mutes` — list this session's active mutes.
- `/ClaudeWatch:rules` — see rule-set names and the individual rule names.
