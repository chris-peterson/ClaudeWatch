# Don't treat ClaudeWatch's ask tier as a confirmation

Whether an `ask` reaches a person depends on how the session was launched and
configured, and the hook cannot tell which case it is in. Known cases:

- **Interactive `auto` runs it unprompted** where the auto-mode server check is
  reachable. The mode clears the call before the hook's `ask` has a surface to
  resolve against
  ([claude-code#89561](https://github.com/anthropics/claude-code/issues/89561)).
  With telemetry or feature flags off, including behind an LLM gateway, Claude
  Code 2.1.319 asks about or denies calls the server can't check instead.
  `auto` is also where a session with no permission mode configured starts; if
  the user expects ClaudeWatch to prompt, tell them to set
  `"permissions": { "defaultMode": "default" }`.
- **`permissions.denyInsteadOfPrompting` denies it**, interactive sessions,
  subagents and teammates included, and the turn continues (Claude Code
  2.1.319).
- **Headless `-p` denies it.** Nothing can answer, so the call fails closed and
  the command has no path forward.
- **A mod's own tool call denies it.** `$.tool.call` opens no prompt, so the
  call does not run (Claude Code 2.1.321).

The `deny` tier is honored in each case, a mod's own calls included.

So when a step is genuinely consequential — a push, a force, a remote branch
delete — say what you are about to do and why in the turn before you do it,
rather than letting the prompt carry that job. And when a guarded command dies
in a headless run or under `denyInsteadOfPrompting`, read the message: an `ask`
that nobody could answer looks the same as a rule that blocked you.
