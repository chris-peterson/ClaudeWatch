---
name: unattended
description: Work while the user is away, making best-judgment calls, logging them, and never waiting on a question, a permission prompt, or a ClaudeWatch ask.
when_to_use: Use when the user says brb or that they're stepping away.
---

# Unattended

The user has delegated work and stepped away. They will review the result
*later* rather than discuss it *now*. For the rest of this session, until they
return and start interacting turn-by-turn again, operate in
**decide-document-proceed** mode.

## Why the default flips

When the user is present, a blocking question is cheap and a wrong guess is
expensive, so you ask. When the user is away it inverts: a blocking question
stalls the entire window (nothing happens until they return, wasting exactly
the time the delegation was meant to use), while a wrong guess gets caught and
corrected at review. So when you would normally stop and ask, instead **make the
call, write it down, and keep going.**

## What invoking this skill turns on

Invoking the skill marks the session unattended, subagents included. While it is
marked:

- **ClaudeWatch's `ask` tier is a block.** A command or file write a watch rule
  would ask about is denied with *"unattended session: escalated to block"*, in
  every permission mode, `auto` included. Nobody is here to answer it, and in
  `auto` it would otherwise run unconfirmed.
- **A host permission prompt is denied at once** with *"Unattended session:
  nobody is here to approve …"*, instead of waiting hours for a click.
- **`AskUserQuestion` is denied before it is shown.** Make the call, record it
  in `NOTES.md`, and keep going.

Both are guarded operations, not shape gates: there is no rewrite that clears
them. Leave the step prepared in the review map.

### Your git toolkit while unattended

Four local git operations still go through, so the work can be segmented into
commits. Each one has to be a bare command (optionally behind `git -C <path>`);
a chained or piped form is denied like any compound. Every use is written as an
`ALLOW` line to the session's unattended log, so the user sees each one on
return.

| Works | For |
| --- | --- |
| `git add <paths>` | staging a batch |
| `git commit -F <path>` | committing it (not `--amend`) |
| `git switch -c <branch>`, `git checkout -b <branch>` | starting a branch |
| `git switch <branch>` | moving between branches (not `-f` / `--discard-changes`) |

Plan the run inside that set. Any other git command that would prompt is denied,
whether or not ClaudeWatch has a rule for it: that covers `git checkout
<branch>`, `merge`, `rebase`, `restore`, `rm`, `mv`, `branch`, `stash`, `reset`,
`push`, and `commit --amend`. Read-only commands (`status`, `diff`, `log`,
`show`) are unaffected unless your session would have prompted on them. Reach
for these instead:

| Instead of | Do |
| --- | --- |
| `git checkout <branch>` | `git switch <branch>` |
| `git commit --amend` | a new commit; note in the review map that it should be squashed |
| `git stash` | commit the work in progress on its own branch |
| `git restore --staged`, `git reset` | leave it staged, or fix it in the next commit, and log the decision |
| `git rm`, `git mv` | plain `rm` / `mv`, then `git add` the old and new paths (which stages the removal); if that prompts too, leave it prepared |
| `git merge`, `git rebase`, `git push` | leave them prepared in the review map |

Any prompt the user types turns the mark off, a message sent mid-turn included,
and a line in your context says so (*"unattended: off"*). Background task
notifications and subagent hand-backs leave it on. When the user sends a
mid-turn instruction and goes again ("carry on, back later"), turn it back on:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/unattended.py" on
```

Check `… unattended.py status` at the start and before you yield to background
work; it counts the calls denied and the ones allowed, which are the real
numbers for **Permission gates hit**.

## First: settle the grant, then set up the notes log

Ask the grant question while the user is still there, as one question before any
work. Commits land on a local branch and are never pushed; dependency installs,
pushes, and other asked-about steps will be left prepared. Confirm which branch
the work goes on (a new one via `git switch -c` is the default), so the user
knows where to look on return.

**Commit each batch without the review pause.** A commit skill that shows the
diff and waits for approval (`/anchor:commit`) needs a person at the desk.
Commit with a bare `git commit -F <path>`, the message written to a `mktemp -u`
file first, and list the commits in the review map as awaiting review so the
user can amend or reword them while they are still unpushed.

**Warn when the machine is on battery.** A laptop that sleeps stops the window as
surely as a prompt does, and nothing inside the turn shows it. Run
`pmset -g batt` (macOS) at the grant. If the first line reads
`Now drawing from 'Battery Power'`, warn them in the same message as the grant
question, with the charge percentage: the run may slow or stop when the machine
sleeps, so plug in before leaving. On `'AC Power'`, say nothing. Staying awake
is the user's setting to manage, so leave power management alone.

Then create the file the review will land on: `NOTES.md` in the working
directory (or a path the user named). Append to it throughout. Each decision
entry:

- **Decision**: what you chose
- **Alternatives**: what else you weighed
- **Why**: the reasoning a reviewer needs
- **Reverse**: how to undo it if it's wrong
- **Confidence**: high / medium / low

Render the path as a clickable link when you surface it so the user can open it.

## While away

1. **Make the most defensible call and keep going.** Pick what a reasonable
   reviewer would most likely endorse: the safest, most reversible, or the
   option the request, issue, or codebase already points at.
2. **Log every call you'd otherwise have asked about.** The log is the artifact;
   the questions you didn't ask become the review agenda.
3. **Keep work reversible and reviewable**: local commits, drafts, scratch
   files.
4. **When one sub-decision is genuinely blocked, block only that step.** Note it
   and keep working everything that doesn't depend on it. Don't abandon the
   whole task because one corner needs the user.
5. **Don't end the turn while work is still runnable.** Ending the turn hands
   control back to a user who isn't there, so the window stops until they
   return: the same failure as asking a question, reached by a different route.
   Status updates are not a reason to yield: write the update *and keep going*
   in the same turn. If background agents are running, keep working the parts
   that don't depend on them rather than yielding to wait. Yield only when the
   work is genuinely done or you are hard-stopped.

## Shape gates still cost a turn

A gate that fires on a command's *shape* (a pipe, an `&&` chain, a `$(…)`)
clears by reshaping, and ClaudeWatch's ambient note "Before you pipe or chain,
check the lead command" carries the rewrites. Two that matter most when nobody
is watching:

- **Prefer file arguments to stdin.** A heredoc piped into a guarded command
  reads as a compound and blocks, where writing the input to a `mktemp -u` path
  and passing the path as a bare call does not.
- **Write `NOTES.md` with the Write tool, never a `cat > … <<'EOF'` heredoc.**
  The rules scan the whole command line, payload included, so a decision entry's
  **Reverse** field trips them: "how to undo it if it's wrong" is exactly where
  `git reset --hard` or `git push --force` gets quoted, and the scanner can't tell
  a quoted example from an invocation. Use the Write tool and the destructive
  string never reaches a shell.

When a *shape* gate fires, it is not a decision to log and route around: reshape
the command and carry on. When a *guarded operation* is what fired, there is
nothing to reshape: leave it prepared in the review map.

**You cannot see how long a call waited.** There is no clock between issuing a
tool call and receiving its result. Never write "the gate cleared" or "no time
lost": those are claims about wall-clock you have no access to.

## Still stop for these

- **Actions beyond the grant.** "Do your best on the work" authorizes
  reversible, local progress, not outward or irreversible steps the user didn't
  bless: pushing, opening PRs or MRs, publishing, sending messages, deleting data
  you didn't create, spending money, mutating shared or production state.
  Default to the reversible form and leave the outward step *prepared and ready*
  in the review map, not executed.
- **A fork so foundational that a wrong guess wastes the whole window.** Don't
  just block: do everything that doesn't depend on the fork first, and if it's
  cheap, prepare both branches. Record it as the first review item. Hard-stop
  only if you truly cannot make progress and cannot hedge.

## This is not a license to guess at facts

Anything verifiable (does the flag exist, what does the schema say, what's the
API shape) you still verify yourself. Unattended mode changes the calculus only
for *judgment and preference decisions that genuinely need the user.* And "do
your best" covers the requested work, not a license to expand scope: tempting
adjacent improvements go in the notes as suggestions, not into the diff.

## Measure the run

Keep a `## Run log` block at the top of `NOTES.md` and update it as you go, so
the review opens on what the window actually produced rather than on your
account of it:

```markdown
## Run log
- Deliverables landed: <commits / files / artifacts>
- Decisions logged: <n>
- Permission gates hit: <n denied, n allowed>  (from `unattended.py status`, plus each shape gate and its reshape)
- Turns yielded with work still runnable: <n>   <- the one to drive to zero
- In flight at close: <what was still running>
```

**Turns yielded with work still runnable is the metric that matters.** The
others describe output; that one measures whether the window was used. A run
with four deliverables and three yields spent most of its time waiting for a
user who was away.

Before writing the review map, list the calls that waited:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/unattended/scripts/tool-waits.py" "$CLAUDE_CODE_SESSION_ID"
```

It pairs each tool call with its result across the session and its subagents
and prints every call that took three minutes or more. A long wait on a quick
command (a `mv`, an Edit) is a prompt that got through to nobody; with the
session marked, there should be none.

None of these are targets to game. They exist so the next run can be compared to
this one, and so a run that stalled can be told apart from a run that was simply
given hard work.

## Wrap-up: the review map

When the work is done (or the window closes), end with a **review map** the
returning user reads first:

0. **The run log**: the counters above, so they can see how the window went
   before reading what came out of it.
1. **What got done**: per deliverable or branch, one line each.
2. **Decisions made**: the high-impact entries from the notes log, with
   confidence.
3. **Open questions and forks**: what you couldn't resolve, ordered by what to
   look at first, and **numbered** so each one is addressable. A returning user
   answers a numbered list one line per item (`3.1 check nuget.org first`); the
   same content in prose costs them a paragraph of re-orientation before they
   can reply to any of it.
4. **Prepared but not executed**: pushes, PRs, installs, sends, each with the
   exact command that runs it. List the local commits beside them as awaiting
   review.
5. **Verified / Unverified**: two lists, and the second one is the point. Name
   every claim you actually exercised (the command you ran, the exit code, the
   live target), then name every claim you *didn't* and why the window couldn't.
6. **Review this first**: your recommended reading order.

**The Unverified list is what earns the review map.** Everything above it
describes work that exists and can be read off the diff; only this section
carries what the diff looks fine about and isn't. It is also the section the
window is structurally worst at producing, because an unattended run ends when
the work stops, not when the checking finishes, so the untested edges are
freshest in your head and about to be forgotten.
