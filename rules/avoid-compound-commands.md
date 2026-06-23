# Run guarded commands on their own, not chained

ClaudeWatch escalates a *compound* Bash command — one that pipes (`|`),
chains (`&&`, `||`), sequences (`;` or a newline), or substitutes (`$(…)`,
backticks) — from an `ask` prompt to a hard block whenever any segment matches
one of its guard rules. The reason: Claude Code's allow list can approve a
pipeline segment-by-segment and auto-run it before the `ask` ever surfaces, so
the block is the only way the confirmation reaches the user.

To stay out of that block, run a consequential step — a commit, a push, an
install, a destructive file operation — as its own Bash call rather than
folding it into a pipe or `&&` chain. When you need a value from one command in
the next, run the first, read its output, then use it in a second call instead
of reaching for `$(…)`. Pipes between plainly-safe commands (`grep … | head`)
stay fine — the escalation fires only when a guarded command is in the chain.
