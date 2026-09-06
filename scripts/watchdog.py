#!/usr/bin/env python3
"""
claude-watchdog: PreToolUse hook for Claude Code

Generic rule engine that enforces safety rules loaded from YAML config files.
Reads tool input JSON from stdin, evaluates all rule sets in a directory,
and outputs a single coalesced JSON decision to stdout.

Supports these tool inputs:
- Bash: matches against tool_input.command (target: bash rules)
- Monitor: matches against tool_input.command (target: bash rules) — the tool
  runs its command in the same shell environment as Bash, so it is screened on
  identical terms
- Write: matches against tool_input.content (target: file-content rules)
- Edit: matches against the full post-edit file content reconstructed from
  the on-disk file plus tool_input.old_string -> tool_input.new_string
  substitution (target: file-content rules)

CLAUDE_PROJECT_DIR, which Claude Code exports to hook commands, is the only
environment variable on the decision path: it bounds the in-tree `rm` exemption
alongside the hook's own cwd (see `_exempt_roots`).

Each decision is appended as a JSONL record to ~/.claude/claudewatch/decisions.jsonl
by default — the side channel the /ClaudeWatch:learn workflow reads. Set
CLAUDEWATCH_LOG to a path to log elsewhere, or to "off" (also 0/false/none/empty)
to disable it. Logging never affects the decision itself.

Every reason reads `<rule>: <reason> — <ref>`, in the prompt and in the log
alike. Deny messages additionally append the `[plugin:ClaudeWatch]` source tag
that Claude Code shows on ask prompts but omits on deny errors; the logged
reasons carry no tag.
"""

import glob
import json
import os
import re
import shlex
import sys


VALID_TARGETS = ("bash", "file-content")


def _unquote(s):
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1].replace("''", "'")
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s


def _split_top_level_commas(s):
    """Split on commas that are outside single/double-quoted spans.

    Lets a quoted list item carry a literal comma — e.g. a regex quantifier
    `{1,2}` in a quoted `unless_regex` entry — without being mis-split.
    """
    items, buf, quote = [], [], None
    for ch in s:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
            buf.append(ch)
        elif ch == ",":
            items.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    if buf:
        items.append("".join(buf))
    return items


def _parse_inline_list(val):
    """Parse YAML inline list syntax like ['.ps1', '.psm1'] or [.ps1, .psm1]."""
    val = val.strip()
    if not (val.startswith("[") and val.endswith("]")):
        return []
    inner = val[1:-1].strip()
    if not inner:
        return []
    return [_unquote(item.strip()) for item in _split_top_level_commas(inner) if item.strip()]


def parse_rules_yml(path):
    """Parse a watchdog rules YAML file without external dependencies.

    Handles the format:
      name: watch-name
      filter: 'optional-regex'           # bash-target only
      extensions: ['.ps1', '.psm1']      # file-content-target only
      rules:
        block:
          - name: ...
            pattern: '...'
            target: bash | file-content  # optional, default bash
            reason: ...
            ref: ...
        ask:
          - name: ...
            pattern: '...'
            target: bash | file-content  # optional, default bash
            reason: ...
            ref: ...
    """
    result = {
        "name": "",
        "filter": "",
        "extensions": [],
        "rules": {"block": [], "ask": []},
    }
    current_section = None
    current_item = None

    with open(path) as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            stripped = line.strip()

            if not stripped or stripped.startswith("#"):
                continue

            indent = len(line) - len(line.lstrip())

            # top-level fields (indent 0)
            if indent == 0 and stripped.startswith("name:"):
                result["name"] = _unquote(stripped[5:].strip())
            elif indent == 0 and stripped.startswith("filter:"):
                result["filter"] = _unquote(stripped[7:].strip())
            elif indent == 0 and stripped.startswith("extensions:"):
                result["extensions"] = _parse_inline_list(stripped[11:].strip())
            elif indent == 0 and stripped == "rules:":
                pass

            # section headers (indent 2)
            elif indent == 2 and stripped in ("block:", "ask:"):
                current_section = stripped[:-1]
                current_item = None

            # list item start (indent 4)
            elif indent == 4 and stripped.startswith("- name:") and current_section is not None:
                current_item = {"name": _unquote(stripped[7:].strip()), "pattern": "", "reason": "", "ref": "", "target": "bash"}
                result["rules"][current_section].append(current_item)

            elif indent == 4 and stripped.startswith("- pattern:") and current_section is not None:
                current_item = {"name": "", "pattern": _unquote(stripped[10:].strip()), "reason": "", "ref": "", "target": "bash"}
                result["rules"][current_section].append(current_item)

            # item fields (indent 6)
            elif indent == 6 and stripped.startswith("pattern:") and current_item is not None:
                current_item["pattern"] = _unquote(stripped[8:].strip())

            elif indent == 6 and stripped.startswith("name:") and current_item is not None:
                current_item["name"] = _unquote(stripped[5:].strip())

            elif indent == 6 and stripped.startswith("reason:") and current_item is not None:
                current_item["reason"] = _unquote(stripped[7:].strip())

            elif indent == 6 and stripped.startswith("ref:") and current_item is not None:
                current_item["ref"] = _unquote(stripped[4:].strip())

            elif indent == 6 and stripped.startswith("target:") and current_item is not None:
                current_item["target"] = _unquote(stripped[7:].strip())

            elif indent == 6 and stripped.startswith("except:") and current_item is not None:
                if current_section == "block":
                    print(f"warning: {result['name'] or path} — rule {current_item.get('name', '?')!r} has 'except' on a block rule (ignored — except only applies to ask rules)", file=sys.stderr)
                else:
                    current_item["except"] = _unquote(stripped[7:].strip())

            elif indent == 6 and stripped.startswith("unless_condition:") and current_item is not None:
                if current_section == "block":
                    print(f"warning: {result['name'] or path} — rule {current_item.get('name', '?')!r} has 'unless_condition' on a block rule (ignored — it only applies to ask rules)", file=sys.stderr)
                else:
                    current_item["unless_condition"] = _parse_inline_list(stripped[17:].strip())

            elif indent == 6 and stripped.startswith("unless_regex:") and current_item is not None:
                if current_section == "block":
                    print(f"warning: {result['name'] or path} — rule {current_item.get('name', '?')!r} has 'unless_regex' on a block rule (ignored — it only applies to ask rules)", file=sys.stderr)
                else:
                    current_item["unless_regex"] = _parse_inline_list(stripped[13:].strip())

            else:
                # Unrecognized line — warn so typos surface instead of silently disappearing.
                label = result["name"] or path
                where = ""
                if indent == 0:
                    where = "top-level"
                elif indent == 2:
                    where = "section header"
                elif indent == 4:
                    where = "list item"
                elif indent == 6:
                    rule_name = current_item.get("name", "?") if current_item else "?"
                    where = f"rule {rule_name!r}"
                else:
                    where = f"indent {indent}"
                print(f"warning: {label} — unrecognized line in {where}: {stripped!r}", file=sys.stderr)

    return result


def _violation(rule):
    """A matched violation as structured data.

    `prefix` is the rule's `name` (the rule-set name is redundant once the
    reason carries the ref, so it's dropped); `reason` is the human prose;
    `ref` is the doc URL (or "" when absent).
    """
    return {"prefix": rule.get("name") or "", "reason": rule["reason"], "ref": rule.get("ref") or ""}


def _error_violation(text):
    """A configuration/load error surfaced as a deny: no prefix, no ref."""
    return {"prefix": "", "reason": text, "ref": ""}


def _message_plain(v):
    """Canonical one-line message: `<prefix>: <reason>[ — <ref>]`.

    Used for both the displayed reason and the decision log the
    `/ClaudeWatch:learn` side channel reads.
    """
    head = f"{v['prefix']}: {v['reason']}" if v["prefix"] else v["reason"]
    return f"{head} — {v['ref']}" if v["ref"] else head


# Source attribution Claude Code shows on ask prompts but omits on deny errors;
# appended to deny reasons so the user always sees which plugin made the call.
_PLUGIN_TAG = "[plugin:ClaudeWatch]"


def _rule_target(rule):
    return rule.get("target") or "bash"


# Quoted spans (single- or double-quoted) carry string data, not shell syntax,
# so they are stripped before scanning for control operators — an operator
# inside a string literal (a pipe in a commit message, a semicolon in a sed
# program) is not a command boundary.
_QUOTED_SPAN = re.compile(r"'[^']*'|\"[^\"]*\"")
# Shell control operators that chain multiple commands: pipe `|` (covers `||`
# and `|&`), sequence `;` / newline, logical `&&`, and command substitution
# `$(` / backtick.
#
# A lone `&` both backgrounds a command and separates it from the next, so it
# counts only when something follows it; a trailing `&` is one command. The
# neighbour tests keep it clear of the redirections it shares a character with
# (`2>&1`, `>&2`, `&>log`), which is why it is not simply in the class above.
#
# A subshell `( … )` and a process substitution `<( … )` / `>( … )` group
# rather than separate, so they carry none of those operators and are matched
# on their own. Restricting the `(` to command position — the string start,
# after a separator or redirection, optionally behind the `time` and `!`
# keywords, which are the two words that may precede a subshell with no
# operator between — leaves a parenthesis inside an argument alone.
_SHELL_COMPOUND = re.compile(
    r"\||;|\n|&&|\$\(|`"
    r"|(?<![>&])&(?![>&])\s*\S"
    r"|(?:^|[;&|<>])\s*(?:(?:!|time)\s+)*\("
)


def _is_compound_command(command):
    """Whether a bash command chains multiple commands via a shell operator.

    The host's allow list can approve each segment of a compound command
    independently and auto-approve the whole, which pre-empts this hook's
    `ask` (a `deny` is honored regardless). Detecting the compound shape lets
    the engine escalate `ask` -> `deny` so the confirmation is not silently
    skipped (see `main`). This detection only ever *tightens* `ask` into
    `deny`; missing a compound form degrades to the existing `ask`, never
    weaker, so the simple quote-stripping (which does not handle escaped
    quotes) stays safe.
    """
    return bool(_SHELL_COMPOUND.search(_QUOTED_SPAN.sub("", command)))


# Where a command word can start: the string start, or after a separator or an
# opening group. `_normalize_command_words` walks these to find each program.
_WORD_POSITION = re.compile(r"(?:^|[;&|(`\n])[ \t]*")
# Where one ends. The bound is what keeps the walk linear: every `(` opens a
# command position, so an unbounded scan makes a run of them cost one pass over
# the rest of the string each. No program or subcommand is this long, and a
# word that overruns the bound stops the walk rather than being truncated into
# one that was never written.
_WORD_STOP = " \t\n;&|`"
_MAX_WORD_LEN = 128
_WORD_SCAN = re.compile(r"[^ \t\n;&|`]{0,%d}" % _MAX_WORD_LEN)
_BARE_WORD = re.compile(r"[\w./-]+\Z")
# POSIX lets a command be prefixed by `VAR=value` assignments and by `sudo`
# without either being the program.
_COMMAND_PREFIX = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*\Z")
# The program plus the subcommands a rule can name. `aws --profile prod s3 rm`
# is the deepest shipped shape once a flag value sits among them.
_MAX_NORMALIZED_WORDS = 4


def _is_command_prefix(word):
    """Whether a word prefixes a command without being its program ([EN-15])."""
    return word == "sudo" or bool(_COMMAND_PREFIX.match(word))


def _unquote_word(word):
    """`"git"` / `g""it` / `g\\it` -> `git`; None when the word isn't one word.

    None means the quoting doesn't resolve inside the word — `"rm` opens a span
    that runs past the whitespace, so the text after it is quoted data and
    normalizing it would invent a command that was never there. The caller
    decides whether the word it resolves to may stand as a program or a
    subcommand; this only reads the quoting the way the shell does.
    """
    try:
        parts = shlex.split(word)
    except ValueError:  # an unbalanced quote or a trailing backslash
        return None
    return parts[0] if len(parts) == 1 and parts[0] else None


def _normalize_command_words(command):
    """Resolve the leading words of each command to the word the shell reads ([EN-15]).

    Walks each command position and rewrites the program, then the words behind
    it, into the single word the shell resolves each to. An option is stepped
    over rather than ending the walk, because git and aws both carry their
    global options ahead of the subcommand a rule matches — so what keeps an
    *operand* out of the rewrite is two guards: a word is rewritten only where
    it resolves to a bare word, so an operand carrying an operator
    (`-m "wip; done"`) stays the quoted data both the rules and [OUT-08] read
    it as; and the word budget bounds how far past the program it reaches.
    """
    out = []
    pos = 0
    for sep in _WORD_POSITION.finditer(command):
        if sep.end() < pos:
            continue
        out.append(command[pos:sep.end()])
        pos = sep.end()
        budget = _MAX_NORMALIZED_WORDS
        program = None
        while budget:
            end = _WORD_SCAN.match(command, pos).end()
            if end < len(command) and command[end] not in _WORD_STOP:
                break
            word = command[pos:end]
            if not word:
                break
            if word.startswith("-") or _is_command_prefix(word):
                # Neither an option nor a `VAR=value`/`sudo` prefix names the
                # program, so neither costs budget.
                out.append(word)
            else:
                resolved = _unquote_word(word)
                if resolved is None:
                    break
                if resolved.startswith("-") or _is_command_prefix(resolved):
                    # The same two, quoted. No spelling of an option names a
                    # program, so `rm "-r" /etc` resolves wherever it sits.
                    out.append(resolved)
                elif not _BARE_WORD.match(resolved):
                    # A path or an option's value, carrying something no
                    # program or subcommand does. It stays exactly as written —
                    # unquoting `-m "wip; done"` would turn a commit message
                    # into what reads as a command boundary — but the walk
                    # continues past it to reach the subcommand behind.
                    if program is None:
                        break
                    out.append(word)
                    budget -= 1
                else:
                    out.append(resolved)
                    if program is None:
                        program = os.path.basename(resolved)
                    budget -= 1
            pos = end
            gap = pos
            while gap < len(command) and command[gap] in " \t":
                gap += 1
            if gap == pos:
                break
            out.append(command[pos:gap])
            pos = gap
    out.append(command[pos:])
    return "".join(out)


# A path token whose on-disk location can't be resolved from the command text
# alone: `~` (home, out of tree), `$` / backtick (unexpanded variable or command
# substitution), `*?[` (glob), or a `..` segment (can escape the tree). A target
# carrying any of these can't be proven in-tree, so the `is_in_project_tree`
# predicate declines and the ask stands.
_UNRESOLVABLE_TARGET = re.compile(r"[~$`*?\[]|(?:^|/)\.\.(?:/|$)")


def _command_operands(command, program):
    """The non-flag operands `program` was invoked with, or None if it wasn't.

    The engine hosts this rather than any one predicate because the syntax it
    parses is POSIX utility convention — leading `VAR=value` assignments,
    `sudo`, flags, the `--` terminator — not knowledge about `rm`. Which
    program to look for is the caller's, so a predicate for a different
    destructive tool reuses this instead of writing its own tokenizer and
    drifting from these guards.

    Returns None when no operands can be attributed: a compound command, a
    parse failure, a different program, or an invocation with no operands.
    """
    # A compound command is handled by the ask->deny escalation ([OUT-08]); don't
    # let an exemption pre-empt that, and don't try to reason about which tokens
    # belong to which segment.
    if _is_compound_command(command):
        return None
    try:
        tokens = shlex.split(command)
    except ValueError:
        return None
    i = 0
    while i < len(tokens) and _is_command_prefix(tokens[i]):
        i += 1
    if i >= len(tokens) or os.path.basename(tokens[i]) != program:
        return None

    operands = []
    after_ddash = False
    for tok in tokens[i + 1:]:
        if not after_ddash and tok == "--":
            after_ddash = True
            continue
        if not after_ddash and tok.startswith("-"):
            continue  # a flag, not an operand
        operands.append(tok)
    return operands or None


def _rm_targets(command):
    """The deletion targets of a plain `rm`, or None when the command isn't one."""
    return _command_operands(command, "rm")


def _exempt_roots(cwd):
    """The roots a delete may be confined to: the working directory and the project root.

    `cwd` follows the session's shell, so it drifts out of the repo the moment
    the session `cd`s into a scratch directory — and an in-repo delete issued
    from there is no less recoverable for it. `CLAUDE_PROJECT_DIR` is the
    project root Claude Code exports to hook commands, so it holds still while
    `cwd` moves. Reading it keeps the decision deterministic in the sense the
    core contract means: a per-invocation input supplied by the host, resolved
    as a string, with no clock, network, or filesystem access.

    `/` and the user's home directory are rejected as roots — a delete anywhere
    beneath either is not what "confined to the working tree" is meant to cover.
    """
    home = os.path.normpath(os.path.expanduser("~"))
    roots = []
    for raw in (cwd, os.environ.get("CLAUDE_PROJECT_DIR")):
        if not raw:
            continue
        root = os.path.normpath(raw)
        if root in (os.sep, home) or not os.path.isabs(root):
            continue
        if root not in roots:
            roots.append(root)
    return roots


def _resolved_targets_in_tree(command, cwd):
    """An `rm` command's targets as absolute paths, when all sit under an exempt root.

    Pure string analysis (no filesystem access) so the decision stays
    deterministic. The roots are the hook's `cwd` and the project root (see
    `_exempt_roots`); relative targets resolve against `cwd`, the only root the
    shell itself would use.

    Returns None — nothing provable, so callers decline — whenever in-tree-ness
    can't be established from the text: no usable root, no attributable
    targets, a target that is a root itself or a `.git` directory, or any
    target carrying an unresolvable marker (`~`, `$`, glob, `..`). A root
    itself and any `.git` directory are excluded because the git-history safety
    net the exemption relies on does not cover wiping the whole tree or its
    history.

    Returns the resolved paths rather than a verdict so `_targets_recoverable`
    interrogates exactly what this proved in-tree.
    """
    roots = _exempt_roots(cwd)
    if not roots:
        return None
    targets = _rm_targets(command)
    if not targets:
        return None

    # Relative targets are resolved by the shell against cwd, so only cwd can
    # resolve them; an absolute target may sit under either root.
    base = os.path.normpath(cwd) if cwd else None
    resolved_targets = []
    for tok in targets:
        if _UNRESOLVABLE_TARGET.search(tok):
            return None
        if os.path.isabs(tok):
            resolved = os.path.normpath(tok)
        elif base:
            resolved = os.path.normpath(os.path.join(base, tok))
        else:
            return None
        for root in roots:
            if resolved != root and resolved.startswith(root + os.sep) \
                    and ".git" not in os.path.relpath(resolved, root).split(os.sep):
                break
        else:
            return None
        resolved_targets.append(resolved)
    return resolved_targets


def _targets_under_cwd(command, cwd):
    """Whether an `rm` command's targets all sit under an exempt root ([RL-16]).

    The in-tree premise — that git history can restore the delete — is assumed
    here, not checked; `_targets_recoverable` is the opt-in variant that
    verifies it.
    """
    return _resolved_targets_in_tree(command, cwd) is not None


# Directories a tool writes and can write again: deleting one loses nothing that
# isn't reproduced by re-running the tool, wherever on disk it sits. Names only —
# a path *inside* one of these is not itself exempt, so the exemption can't be
# widened by appending a subdirectory.
_EPHEMERAL_SCRATCH_DIRS = frozenset((
    ".playwright-mcp",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
))


def _targets_are_ephemeral_scratch(command, cwd):
    """Whether every deletion target of an `rm` command names a regenerable tool directory.

    Backs the `is_ephemeral_scratch` unless-condition. Unlike
    `is_in_project_tree` this ignores where the target sits — the premise is the
    directory's *identity*, not its location, so a session that has `cd`'d
    elsewhere still clears its own build cache without a prompt.

    Matches on the final path segment against `_EPHEMERAL_SCRATCH_DIRS`, and
    declines on the same unresolvable markers the in-tree predicate rejects, so
    a glob or variable can never stand in for the name.
    """
    targets = _rm_targets(command)
    if not targets:
        return False
    for tok in targets:
        if _UNRESOLVABLE_TARGET.search(tok):
            return False
        if os.path.basename(os.path.normpath(tok)) not in _EPHEMERAL_SCRATCH_DIRS:
            return False
    return True


_PROBE_TIMEOUT = 3


def _probe(argv):
    """Run a read-only command and return its stdout, or None if it gave no answer.

    None covers every way a check can fail to complete — the tool is absent, it
    timed out, it exited non-zero — because callers treat them identically:
    a check that cannot run never grants an exemption. Folding the exit status
    into the return value is what keeps those call sites to one guard each.

    `subprocess` is imported here rather than at module scope: only the opt-in
    `is_recoverable` predicate reaches this, and the import costs several
    milliseconds that every other hook invocation would otherwise pay.
    """
    import subprocess

    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=_PROBE_TIMEOUT)
    except Exception:
        return None
    return result.stdout if result.returncode == 0 else None


def _git(cwd, *args):
    """Read-only git in `cwd` — stdout, or None if it gave no answer."""
    return _probe(["git", "-C", cwd, *args])


def _is_submodule(ls_files_stage_line):
    """Whether a `git ls-files --stage` line describes a submodule.

    Each line is `<mode> <sha> <stage>\t<path>`, and git records a submodule as
    a "gitlink" — mode 160000, the one mode that points at another repository
    rather than at content in this one. That matters here because a gitlink is
    tracked, so it satisfies a tracked-ness check, while the work inside the
    submodule is in a different repository that the superproject's commands
    never look into.
    """
    return ls_files_stage_line.split()[:1] == ["160000"]


def _git_recoverable(roots, targets):
    """Whether git could restore every one of `targets` after a recursive delete.

    Two questions, and the call count does not grow with the number of targets —
    both commands take every target as pathspecs in one invocation. That matters
    because this runs on the PreToolUse path, where each call is latency the user
    waits through before their prompt appears.

    1. Is every target tracked, and is none of them a submodule? `ls-files
       --stage --error-unmatch` exits non-zero on the first pathspec matching no
       tracked file — which also answers "is this a work tree at all", since it
       fails the same way outside one — and `--stage` reports each entry's mode
       in the same output, so a gitlink (`160000`) costs no extra call. A
       submodule is declined rather than answered for: the superproject's index
       records only which commit it points at, and neither of these commands
       reaches inside it, so uncommitted work in there is invisible here.
    2. Does any target hold content git would not bring back? `ls-files --others
       --modified` lists, in one pass, files that are untracked, ignored (no
       `--exclude-standard`), or tracked-but-edited. All three are lost with a
       directory — a stray build artifact and an uncommitted edit alike — so any
       of them means the delete is not recoverable.

    `git` runs from the first root it recognizes, not from `cwd`. A target can be
    proved in-tree via the project root while `cwd` sits somewhere else entirely
    (see `_exempt_roots`), and asking `cwd`'s repo about a path it doesn't
    contain answers the wrong question.

    `ls-files` rather than `status`: status refreshes and rewrites `.git/index`,
    taking `index.lock` on what is meant to be a read-only probe, and would race
    a concurrent git operation in the user's own terminal.
    """
    for root in roots:
        listing = _git(root, "ls-files", "--stage", "--error-unmatch", "--", *targets)
        if listing is None:
            continue
        if any(_is_submodule(line) for line in listing.splitlines()):
            return False
        unrestorable = _git(root, "ls-files", "--others", "--modified", "--", *targets)
        return unrestorable is not None and not unrestorable.strip()
    return False


def _targets_recoverable(command, cwd):
    """Whether every deletion target is in-tree AND actually recoverable.

    Backs the opt-in `is_recoverable` unless-condition ([RL-18]). Where
    `is_in_project_tree` treats "under an exempt root" as standing in for
    "recoverable from git history", this checks that directly — git must be
    able to restore every target. Location is a proxy that fails exactly where
    it matters: a workspace root grouping several checkouts is not itself a
    repo, so a delete there has no history behind it.

    Git is the only backend. A path some other tool could restore — a dotfile
    manager's target, say — is not exempted here; `unless_regex` on the path is
    how a rule set expresses a known-safe location it knows about and the
    engine does not.

    Scratch paths under `/tmp` and friends never reach here — `watch-files`
    exempts them by `unless_regex` first, and requiring ephemeral space to be
    version-controlled would defeat that exemption.
    """
    targets = _resolved_targets_in_tree(command, cwd)
    if targets is None:
        return False
    return _git_recoverable(_exempt_roots(cwd), targets)


# Named predicates an `unless_condition` entry can reference. Each takes the bash
# command and the hook's `cwd` and returns True when the rule's ask should be
# skipped. Keep this the single registry of valid condition names — an unknown
# name surfaces as a config-error deny rather than silently never matching.
_PREDICATES = {
    "is_in_project_tree": _targets_under_cwd,
    "is_ephemeral_scratch": _targets_are_ephemeral_scratch,
    "is_recoverable": _targets_recoverable,
}


def _is_exempted(rule, input_kind, input_text, cwd):
    """Whether an ask rule's `except` / `unless_*` exemptions skip it.

    Returns (exempted, error). `exempted` is True when the legacy `except`
    regex, any `unless_regex` entry, or any `unless_condition` predicate matches
    — the rule's ask is then suppressed (the exemptions are OR'd). `error` is a
    message when a regex is malformed or a condition names an unknown predicate,
    which the caller surfaces as a config-error deny. Predicates apply to bash
    input only.
    """
    exc = rule.get("except")
    if exc:
        try:
            if re.search(exc, input_text):
                return True, None
        except re.error as e:
            return False, f"has invalid 'except' regex: {e}"
    for rx in rule.get("unless_regex", []):
        try:
            if re.search(rx, input_text):
                return True, None
        except re.error as e:
            return False, f"has invalid 'unless_regex' entry: {e}"
    for cond in rule.get("unless_condition", []):
        pred = _PREDICATES.get(cond)
        if pred is None:
            return False, f"references unknown unless_condition {cond!r}"
        if input_kind == "bash" and pred(input_text, cwd):
            return True, None
    return False, None


def _compound_escalation():
    """The note prepended when an `ask` is escalated to `deny` for a compound command."""
    return {
        "prefix": "compound command",
        "reason": "escalated to block — a compound command or subshell can be auto-approved segment-by-segment by the host allow list, which skips this confirmation; run the guarded command on its own to be prompted",
        "ref": "",
    }


def evaluate_rules(config, input_kind, input_text, file_extension=None, cwd=None):
    """Evaluate a single rule set against an input.

    input_kind is "bash" or "file-content". input_text is the string to match
    against. file_extension is the lowercase extension (including the dot) of
    the target file, used to filter rule sets for file-content inputs. cwd is
    the working directory from the hook input, used by the `is_in_project_tree`
    unless-condition to tell in-tree deletes from out-of-tree ones.

    Returns (blocks, asks) — lists of violation dicts (see `_violation`).
    """
    blocks = []
    asks = []
    label = config.get("name") or "unknown"

    def _block(reason):
        blocks.append(_error_violation(reason))

    if input_kind == "bash":
        filt = config.get("filter")
        if filt:
            try:
                if not re.search(filt, input_text):
                    return blocks, asks
            except re.error as e:
                _block(f"{label} — invalid filter regex: {e}")
                return blocks, asks
    else:  # file-content
        extensions = config.get("extensions") or []
        if not extensions:
            return blocks, asks
        if file_extension is None or file_extension.lower() not in [e.lower() for e in extensions]:
            return blocks, asks

    rules = config.get("rules", {})

    for rule in rules.get("block", []):
        target = _rule_target(rule)
        if target not in VALID_TARGETS:
            _block(f"{label} — rule {rule.get('name', '?')!r} has invalid target {target!r}")
            continue
        if target != input_kind:
            continue
        if not rule.get("pattern"):
            _block(f"{label} — rule {rule.get('name', '?')!r} has empty pattern")
            continue
        try:
            if re.search(rule["pattern"], input_text):
                blocks.append(_violation(rule))
        except re.error as e:
            _block(f"{label} — rule {rule.get('name', '?')!r} has invalid regex: {e}")

    for rule in rules.get("ask", []):
        target = _rule_target(rule)
        if target not in VALID_TARGETS:
            _block(f"{label} — rule {rule.get('name', '?')!r} has invalid target {target!r}")
            continue
        if target != input_kind:
            continue
        if not rule.get("pattern"):
            _block(f"{label} — rule {rule.get('name', '?')!r} has empty pattern")
            continue
        try:
            matched = bool(re.search(rule["pattern"], input_text))
        except re.error as e:
            _block(f"{label} — rule {rule.get('name', '?')!r} has invalid regex: {e}")
            continue
        if not matched:
            continue
        exempted, err = _is_exempted(rule, input_kind, input_text, cwd)
        if err:
            _block(f"{label} — rule {rule.get('name', '?')!r} {err}")
            continue
        if exempted:
            continue
        asks.append(_violation(rule))

    return blocks, asks


DEFAULT_LOG_PATH = "~/.claude/claudewatch/decisions.jsonl"
_LOG_OFF_VALUES = frozenset(("", "off", "0", "false", "none"))
_LOG_DEFAULT_VALUES = frozenset(("1", "true", "on", "yes"))
# Log schema version, written as the header line `{"schema": N}` ([LOG-06]).
# 1 = pre-shape format (recorded the raw command string); 2 = command-shape
# format ([LOG-03]). A log whose header is missing or older is discarded on the
# next write so raw commands from before an upgrade are not carried forward.
LOG_SCHEMA_VERSION = 2


def _log_schema_of(dest):
    """Return the schema version from the log's header line, or None if absent."""
    try:
        with open(dest) as f:
            first = f.readline()
    except OSError:
        return None
    try:
        return json.loads(first).get("schema")
    except (ValueError, AttributeError):
        return None

# Tools whose first argument is a subcommand worth keeping in the shape, so
# `git push` and `git status` group separately rather than collapsing to `git`.
SUBCOMMAND_TOOLS = frozenset((
    "git", "gh", "glab", "npm", "npx", "yarn", "pnpm", "pip", "pip3", "cargo",
    "go", "docker", "kubectl", "just", "make", "brew", "terraform", "bundle",
    "rake", "dotnet", "aws", "gcloud", "az", "systemctl", "apt", "apt-get",
    "uv", "poetry", "deno", "bun",
))
# A subcommand token is a bare lowercase word (e.g. `pr`, `view`, `commit`).
# Stopping at the first flag, path, or value keeps the shape free of secrets and
# keeps the learn skill's suggested allow pattern as narrow as the real commands.
_SUBCOMMAND_LIKE = re.compile(r"^[a-z][a-z0-9-]*$")
_MAX_SHAPE_TOKENS = 4


def command_shape(command, tool):
    """Reduce a bash command to a stable, secret-free grouping prefix.

    Skips leading `VAR=value` assignments and `sudo`, then keeps the program and
    (for known subcommand tools) its leading subcommand tokens, stopping at the
    first flag, path, or value. Returns `(shape, allow_pattern)`, where the
    pattern names `tool` because a host `Bash(…)` allow rule does not cover the
    same command issued through `Monitor`. This is what
    `[LOG-03]` records in place of the raw command, and what `/ClaudeWatch:learn`
    groups by — defined here so the engine (which writes the log) and the
    analyzer (which reads it) share one definition. Applying it to an already-
    reduced shape is idempotent, so the analyzer can re-derive the pattern from a
    logged shape.
    """
    tokens = command.strip().split()
    i = 0
    while i < len(tokens) and _is_command_prefix(tokens[i]):
        i += 1
    if i >= len(tokens):
        return command.strip(), f"{tool}({command.strip()})"

    prog = os.path.basename(tokens[i])
    shape_tokens = [prog]
    if prog in SUBCOMMAND_TOOLS:
        j = i + 1
        while j < len(tokens) and len(shape_tokens) < _MAX_SHAPE_TOKENS and _SUBCOMMAND_LIKE.match(tokens[j]):
            shape_tokens.append(tokens[j])
            j += 1

    shape = " ".join(shape_tokens)
    return shape, f"{tool}({shape}:*)"


def _log_event(data, input_kind, input_text, decision, matched):
    """Append a decision record to the log unless logging is disabled.

    The side channel the `/ClaudeWatch:learn` workflow reads. It never
    influences the decision (which stays a pure function of command + rules)
    and never changes the exit code. A log-write failure is reported to stderr
    and swallowed so the hook still returns its decision.

    Destination resolution (case-insensitive) of CLAUDEWATCH_LOG:
      - unset, "1"/"true"/"on"/"yes" -> default path ~/.claude/claudewatch/decisions.jsonl
      - "off"/"0"/"false"/"none"/"" -> logging disabled (this is the opt-out)
      - anything else -> treated as the destination path
    """
    raw = os.environ.get("CLAUDEWATCH_LOG")
    if raw is None:
        dest = DEFAULT_LOG_PATH
    else:
        token = raw.strip().lower()
        if token in _LOG_OFF_VALUES:
            return
        dest = DEFAULT_LOG_PATH if token in _LOG_DEFAULT_VALUES else raw
    dest = os.path.expanduser(dest)

    from datetime import datetime, timezone

    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "session": data.get("session_id"),
        "cwd": data.get("cwd"),
        "tool": data.get("tool_name"),
        "mode": data.get("permission_mode"),
        "decision": decision,
        "matched": matched,
    }
    if input_kind == "bash":
        # Log the shape, not the raw command: a command can carry inline secrets
        # (credentials in flags, URLs, or VAR=value prefixes), and the durable log
        # is plaintext ([LOG-03]). The shape drops everything past the program and
        # its subcommand tokens, so no secret survives into the log.
        entry["command_shape"] = command_shape(input_text, entry["tool"])[0]
    else:
        tool_input = data.get("tool_input", {}) or {}
        entry["path"] = tool_input.get("file_path")

    try:
        parent = os.path.dirname(dest)
        if parent:
            os.makedirs(parent, mode=0o700, exist_ok=True)
        # Start a fresh, versioned log when none exists or the existing one is from
        # an older schema ([LOG-06]). A pre-shape log holds raw commands that may
        # carry inline secrets, so discard rather than carry it across an upgrade.
        write_header = not os.path.exists(dest)
        if not write_header and _log_schema_of(dest) != LOG_SCHEMA_VERSION:
            had_content = os.path.getsize(dest) > 0
            os.remove(dest)
            write_header = True
            if had_content:
                print(f"watchdog: cleared a pre-schema-{LOG_SCHEMA_VERSION} decision log "
                      f"(it recorded raw commands); starting a fresh shape-only log at {dest}",
                      file=sys.stderr)
        with open(dest, "a") as f:
            if write_header:
                f.write(json.dumps({"schema": LOG_SCHEMA_VERSION}, separators=(",", ":")) + "\n")
            f.write(json.dumps(entry, separators=(",", ":")) + "\n")
        # Owner-only access ([LOG-05]). Applied every write so a pre-existing
        # wider mode (e.g. a 0644 log from before this was enforced) is corrected.
        os.chmod(dest, 0o600)
        if parent:
            os.chmod(parent, 0o700)
    except OSError as e:
        print(f"watchdog: failed to write decision log to {dest}: {e}", file=sys.stderr)


def _resolve_input(data):
    """Map tool_input -> (input_kind, input_text, file_extension) or None."""
    tool_name = data.get("tool_name")
    tool_input = data.get("tool_input", {}) or {}

    # A Monitor command runs in the same shell environment as a Bash command,
    # so it is the same input kind ([EN-14]). Monitor's `ws` form carries no
    # command and falls through to the empty-input exit ([EN-03]).
    if tool_name in ("Bash", "Monitor"):
        cmd = tool_input.get("command", "")
        if not cmd:
            return None
        return "bash", _normalize_command_words(cmd), None

    if tool_name == "Write":
        content = tool_input.get("content", "")
        path = tool_input.get("file_path", "") or ""
        if not content:
            return None
        return "file-content", content, os.path.splitext(path)[1]

    if tool_name == "Edit":
        path = tool_input.get("file_path", "") or ""
        old_string = tool_input.get("old_string", "")
        new_string = tool_input.get("new_string", "")
        replace_all = bool(tool_input.get("replace_all", False))
        if not new_string and not old_string:
            return None
        try:
            with open(path) as f:
                existing = f.read()
            if replace_all:
                content = existing.replace(old_string, new_string)
            else:
                content = existing.replace(old_string, new_string, 1)
        except (OSError, FileNotFoundError):
            content = new_string
        if not content:
            return None
        return "file-content", content, os.path.splitext(path)[1]

    return None


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"watchdog: invalid JSON on stdin: {e}", file=sys.stderr)
        sys.exit(0)

    resolved = _resolve_input(data)
    if resolved is None:
        sys.exit(0)
    input_kind, input_text, file_extension = resolved
    cwd = data.get("cwd")

    if len(sys.argv) > 1:
        target = sys.argv[1]
    else:
        target = os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "watches")

    def _emit(decision, reason):
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": reason,
            }
        }, separators=(",", ":")))

    if os.path.isdir(target):
        rule_files = sorted(glob.glob(os.path.join(target, "*.yml")))
    elif os.path.isfile(target):
        rule_files = [target]
    else:
        _emit("deny", f"watchdog: rules not found: {target}")
        sys.exit(0)

    all_blocks = []
    all_asks = []

    for rule_file in rule_files:
        try:
            config = parse_rules_yml(rule_file)
        except Exception as e:
            all_blocks.append(_error_violation(f"watchdog: failed to load rules: {e}"))
            continue
        blocks, asks = evaluate_rules(config, input_kind, input_text, file_extension, cwd)
        all_blocks.extend(blocks)
        all_asks.extend(asks)

    if all_blocks:
        decision, chosen = "deny", all_blocks
    elif all_asks:
        decision, chosen = "ask", all_asks
    else:
        decision, chosen = "allow", []

    # A compound bash command (pipe, chain, sequence, substitution) can be
    # auto-approved by the host segment-by-segment, which pre-empts an `ask`. A
    # `deny` is honored regardless, so escalate `ask` -> `deny` and tell the
    # user to re-run the guarded command on its own. Bare commands keep `ask`.
    if decision == "ask" and input_kind == "bash" and _is_compound_command(input_text):
        decision, chosen = "deny", [_compound_escalation()] + chosen

    messages = [_message_plain(v) for v in chosen]
    _log_event(data, input_kind, input_text, decision, messages)

    if decision != "allow":
        reason = "\n".join(messages)
        # Claude Code tags ask prompts with the source plugin but leaves deny
        # errors unattributed, so append the tag ourselves on the deny path to
        # match — the user should always see which plugin made the call.
        if decision == "deny":
            reason += f" {_PLUGIN_TAG}"
        _emit(decision, reason)

    sys.exit(0)


if __name__ == "__main__":
    main()
