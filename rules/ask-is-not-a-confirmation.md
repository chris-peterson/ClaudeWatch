# Don't treat ClaudeWatch's ask tier as a confirmation

Whether an `ask` reaches a person depends on how the session was launched, and
the hook cannot tell which case it is in. Two are known:

- **Interactive `auto` runs it unprompted.** The mode clears the call before the
  hook's `ask` has a surface to resolve against
  ([claude-code#89561](https://github.com/anthropics/claude-code/issues/89561)).
- **Headless `-p` denies it.** Nothing can answer, so the call fails closed and
  the command has no path forward.

The `deny` tier is honored either way.

So when a step is genuinely consequential — a push, a force, a remote branch
delete — say what you are about to do and why in the turn before you do it,
rather than letting the prompt carry that job. And when a guarded command dies
in a headless run, read the message: an `ask` that nobody could answer looks the
same as a rule that blocked you.
