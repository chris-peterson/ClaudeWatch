# Before you pipe or chain, check the lead command

Reaching for `| tail`, `2>&1 | head`, or `$(…)` to shape a command's output is
the reflex that trips this. When the command you're wrapping is a commit, a
push, an install, or a destructive op (`git push`, `git commit`, `npm install`,
`rm -rf`), ClaudeWatch escalates the whole compound from an `ask` prompt to a hard block.
The reason: Claude Code's allow list can approve a pipeline segment-by-segment
and auto-run it before the `ask` ever surfaces, so the block is the only way the
confirmation reaches the user.

So run the consequential step as its own bare Bash call — `git push` on one
line, then read what it printed — rather than folding it into a pipe, an `&&`
chain, a `$(…)`, or a `( … )` subshell. Its output is usually short enough that
the `| tail` bought you nothing. When you need a value from one command in the
next, run the first, read its result, then use it in a second call. Pipes
between plainly-safe commands (`grep … | head`) stay fine — the escalation
fires only when a guarded command is in the chain.

The same applies to a `Monitor` command, which runs in the same shell and is
screened the same way. A watch loop is compound by construction, so a guarded
command inside one is escalated too — and it would run unattended, repeatedly,
on a single approval. Keep monitors to the watching (`tail -f … | grep`, a
status poll) and run the consequential step yourself as its own Bash call.
