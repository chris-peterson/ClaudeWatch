#!/usr/bin/env python3
"""
claude-watchdog: PreToolUse hook for Claude Code

Generic rule engine that enforces safety rules loaded from YAML config files.
Reads tool input JSON from stdin, evaluates all rule sets in a directory,
and outputs a single coalesced JSON decision to stdout.

Supports three tool inputs:
- Bash: matches against tool_input.command (target: bash rules)
- Write: matches against tool_input.content (target: file-content rules)
- Edit: matches against the full post-edit file content reconstructed from
  the on-disk file plus tool_input.old_string -> tool_input.new_string
  substitution (target: file-content rules)

Each decision is appended as a JSONL record to ~/.claude/claudewatch/decisions.jsonl
by default — the side channel the /ClaudeWatch:learn workflow reads. Set
CLAUDEWATCH_LOG to a path to log elsewhere, or to "off" (also 0/false/none/empty)
to disable it. Logging never affects the decision itself.

The ask-prompt reason reads `<rule>: <reason>`, where the reason prose is a
clickable OSC 8 terminal hyperlink to the rule's `ref` — so the verbose URL
stays out of the line. Set CLAUDEWATCH_HYPERLINKS to "off" (also
0/false/none/empty) to keep the plain `— <url>` form instead. Deny messages
always use the plain `— <url>` form: Claude Code renders them through its error
path, which strips OSC 8 without linking it. Deny messages also append the
`[plugin:ClaudeWatch]` source tag that Claude Code shows on ask prompts but
omits on deny errors. The logged reasons stay plain text regardless — no tag.
"""

import glob
import json
import os
import re
import shlex
import sys


VALID_TARGETS = ("bash", "file-content")


# --- Session mute store (MUTE-01..MUTE-04) ------------------------------------
# A session mute suppresses *ask* rules (never block rules) for the duration of
# one Claude Code session. The engine reads the muted-name set keyed by the
# hook's session_id — a pure file read on the decision path, no clock/network,
# so determinism holds ([EN], MUTE-03). The store lives in a fixed user
# directory so its path resolves identically for the engine, the `mute.py` CLI,
# and the session hooks regardless of installed plugin version (MUTE-04).
# CLAUDEWATCH_HOME overrides the root (used by tests); default ~/.claude/claudewatch.

def _claudewatch_home():
    return os.path.expanduser(os.environ.get("CLAUDEWATCH_HOME") or "~/.claude/claudewatch")


def mutes_dir():
    return os.path.join(_claudewatch_home(), "mutes")


# A session id comes from Claude Code (a UUID) or the hook's `session_id`, and
# is the only place that value is used as a path component. Validate it before
# it becomes a filename so a stray separator or `..` segment can't escape the
# mutes directory.
_SAFE_SESSION_ID = re.compile(r"[A-Za-z0-9_-]+")


def valid_session_id(session_id):
    """True when session_id is safe to use as a mute-file name (no path parts)."""
    return isinstance(session_id, str) and _SAFE_SESSION_ID.fullmatch(session_id) is not None


def mute_file(session_id):
    if not valid_session_id(session_id):
        raise ValueError(f"unsafe session id: {session_id!r}")
    return os.path.join(mutes_dir(), f"{session_id}.json")


def short_set_name(set_name):
    """The `/ClaudeWatch:rules` short name: the set name minus its `watch-` prefix."""
    return set_name[len("watch-"):] if set_name.startswith("watch-") else set_name


def load_session_mutes(session_id):
    """Return the set of muted names for a session (empty when none/unreadable).

    A pure read on the decision path (MUTE-03): a missing or malformed store is
    an empty mute set, never an error — silence is allow, and a broken mute file
    must never turn a normal ask into anything else.
    """
    if not session_id:
        return set()
    try:
        with open(mute_file(session_id)) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return set()
    mutes = data.get("mutes") if isinstance(data, dict) else data
    return set(mutes) if isinstance(mutes, (list, set)) else set()


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
    reason links to the ref, so it's dropped); `reason` is the human prose;
    `ref` is the doc URL (or "" when absent). Keeping them apart lets the
    prompt make the *prose* the hyperlink while the log stays plain
    (`_message_plain`).
    """
    return {"prefix": rule.get("name") or "", "reason": rule["reason"], "ref": rule.get("ref") or ""}


def _error_violation(text):
    """A configuration/load error surfaced as a deny: no prefix, no ref."""
    return {"prefix": "", "reason": text, "ref": ""}


def _message_plain(v):
    """Canonical one-line message: `<prefix>: <reason>[ — <ref>]`.

    This is what gets written to the decision log, so the `/ClaudeWatch:learn`
    side channel always reads plain text — never escape sequences.
    """
    head = f"{v['prefix']}: {v['reason']}" if v["prefix"] else v["reason"]
    return f"{head} — {v['ref']}" if v["ref"] else head


_OSC8 = "\x1b]8;;"
_ST = "\x1b\\"

# Source attribution Claude Code shows on ask prompts but omits on deny errors;
# appended to deny reasons so the user always sees which plugin made the call.
_PLUGIN_TAG = "[plugin:ClaudeWatch]"


def _hyperlink(url, text):
    """Wrap `text` in an OSC 8 terminal hyperlink pointing at `url`."""
    return f"{_OSC8}{url}{_ST}{text}{_OSC8}{_ST}"


_HYPERLINKS_OFF_VALUES = frozenset(("off", "0", "false", "none", ""))


def _hyperlinks_enabled():
    """Whether the displayed reason renders refs as terminal hyperlinks.

    On by default. Set CLAUDEWATCH_HYPERLINKS to off/0/false/none/empty
    (case-insensitive) to fall back to the plain `— <url>` form — for
    terminals without OSC 8 support or anyone who prefers the bare URL.
    """
    raw = os.environ.get("CLAUDEWATCH_HYPERLINKS")
    if raw is None:
        return True
    return raw.strip().lower() not in _HYPERLINKS_OFF_VALUES


def _message_display(v, hyperlinks):
    """The reason line shown in the permission prompt.

    With hyperlinks on and a ref present, the reason prose itself becomes the
    clickable link to the ref — so it reads `<prefix>: <prose>` with the prose
    clickable — keeping the verbose URL out of the line. Otherwise it matches
    the plain log form.
    """
    if hyperlinks and v["ref"]:
        linked = _hyperlink(v["ref"], v["reason"])
        return f"{v['prefix']}: {linked}" if v["prefix"] else linked
    return _message_plain(v)


def _rule_target(rule):
    return rule.get("target") or "bash"


# Quoted spans (single- or double-quoted) carry string data, not shell syntax,
# so they are stripped before scanning for control operators — an operator
# inside a string literal (a pipe in a commit message, a semicolon in a sed
# program) is not a command boundary.
_QUOTED_SPAN = re.compile(r"'[^']*'|\"[^\"]*\"")
# Shell control operators that chain multiple commands: pipe `|` (covers `||`
# and `|&`), sequence `;` / newline, logical `&&`, and command substitution
# `$(` / backtick. A lone `&` is intentionally absent — it appears in
# redirections like `2>&1` and matching it would mis-flag a single command.
_SHELL_COMPOUND = re.compile(r"\||;|\n|&&|\$\(|`")


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


# A path token whose on-disk location can't be resolved from the command text
# alone: `~` (home, out of tree), `$` / backtick (unexpanded variable or command
# substitution), `*?[` (glob), or a `..` segment (can escape the tree). A target
# carrying any of these can't be proven in-tree, so the `is_relative_to_cwd`
# predicate declines and the ask stands.
_UNRESOLVABLE_TARGET = re.compile(r"[~$`*?\[]|(?:^|/)\.\.(?:/|$)")


def _targets_under_cwd(command, cwd):
    """Whether every deletion target of an `rm` command resolves strictly under `cwd`.

    Pure string analysis (no filesystem access) so the decision stays
    deterministic. Backs the `is_relative_to_cwd` unless-condition: an in-tree
    `rm -r` is recoverable from git history, so it need not prompt, while a
    delete that reaches outside the working directory still does.

    Returns False — decline the exemption, keep the ask — whenever in-tree-ness
    can't be proven from the text: no cwd, a compound command, a parse failure,
    a non-`rm` program, no targets, a target that is the working directory
    itself or a `.git` directory, or any target carrying an unresolvable marker
    (`~`, `$`, glob, `..`). Only an all-clear set of literal paths strictly
    under cwd returns True. The working directory itself and any `.git`
    directory are excluded because the git-history safety net the exemption
    relies on does not cover wiping the whole tree or its history.
    """
    if not cwd:
        return False
    # A compound command is handled by the ask->deny escalation ([OUT-08]); don't
    # let the exemption pre-empt that, and don't try to reason about which tokens
    # belong to which segment.
    if _is_compound_command(command):
        return False
    try:
        tokens = shlex.split(command)
    except ValueError:
        return False
    # Skip leading `VAR=value` assignments and `sudo` to reach the program.
    i = 0
    while i < len(tokens) and (re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", tokens[i]) or tokens[i] == "sudo"):
        i += 1
    if i >= len(tokens) or os.path.basename(tokens[i]) != "rm":
        return False

    targets = []
    after_ddash = False
    for tok in tokens[i + 1:]:
        if not after_ddash and tok == "--":
            after_ddash = True
            continue
        if not after_ddash and tok.startswith("-"):
            continue  # a flag, not a target
        targets.append(tok)
    if not targets:
        return False

    cwd_norm = os.path.normpath(cwd)
    for tok in targets:
        if _UNRESOLVABLE_TARGET.search(tok):
            return False
        resolved = os.path.normpath(tok if os.path.isabs(tok) else os.path.join(cwd_norm, tok))
        if resolved == cwd_norm or not resolved.startswith(cwd_norm + os.sep):
            return False
        if ".git" in os.path.relpath(resolved, cwd_norm).split(os.sep):
            return False
    return True


# Named predicates an `unless_condition` entry can reference. Each takes the bash
# command and the hook's `cwd` and returns True when the rule's ask should be
# skipped. Keep this the single registry of valid condition names — an unknown
# name surfaces as a config-error deny rather than silently never matching.
_PREDICATES = {
    "is_relative_to_cwd": _targets_under_cwd,
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
        "reason": "escalated to block — a piped or chained command can be auto-approved segment-by-segment by the host allow list, which skips this confirmation; run the guarded command on its own to be prompted",
        "ref": "",
    }


def evaluate_rules(config, input_kind, input_text, file_extension=None, cwd=None, muted=None):
    """Evaluate a single rule set against an input.

    input_kind is "bash" or "file-content". input_text is the string to match
    against. file_extension is the lowercase extension (including the dot) of
    the target file, used to filter rule sets for file-content inputs. cwd is
    the working directory from the hook input, used by the `is_relative_to_cwd`
    unless-condition to tell in-tree deletes from out-of-tree ones. muted is the
    active session's set of muted names ([MUTE-02]); a matched ask rule is
    skipped when its rule-set name, rule-set short name, or rule name is muted.
    Block rules ignore `muted` entirely ([MUTE-01]).

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
        rule_name = rule.get("name") or ""
        # A session mute suppresses this ask when its rule-set name, rule-set
        # short name, or rule name is muted ([MUTE-02]). Block rules never
        # consult this. Matching on the rule name (not a positional id) keeps the
        # mute token the same label the ask prompt already shows.
        if muted and ({label, short_set_name(label), rule_name} & muted):
            continue
        violation = _violation(rule)
        # The friction hint ([MUTE-08]) suggests muting this specific rule by its
        # name. A nameless ask rule has no per-rule token; falling back to the set
        # short name would suggest a command that silences the whole set, so leave
        # it empty (the hint filters falsy tokens) rather than over-mute.
        violation["mute_token"] = rule_name
        asks.append(violation)

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


def command_shape(command):
    """Reduce a bash command to a stable, secret-free grouping prefix.

    Skips leading `VAR=value` assignments and `sudo`, then keeps the program and
    (for known subcommand tools) its leading subcommand tokens, stopping at the
    first flag, path, or value. Returns `(shape, allow_pattern)`. This is what
    `[LOG-03]` records in place of the raw command, and what `/ClaudeWatch:learn`
    groups by — defined here so the engine (which writes the log) and the
    analyzer (which reads it) share one definition. Applying it to an already-
    reduced shape is idempotent, so the analyzer can re-derive the pattern from a
    logged shape.
    """
    tokens = command.strip().split()
    i = 0
    while i < len(tokens) and (re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", tokens[i]) or tokens[i] == "sudo"):
        i += 1
    if i >= len(tokens):
        return command.strip(), f"Bash({command.strip()})"

    prog = os.path.basename(tokens[i])
    shape_tokens = [prog]
    if prog in SUBCOMMAND_TOOLS:
        j = i + 1
        while j < len(tokens) and len(shape_tokens) < _MAX_SHAPE_TOKENS and _SUBCOMMAND_LIKE.match(tokens[j]):
            shape_tokens.append(tokens[j])
            j += 1

    shape = " ".join(shape_tokens)
    return shape, f"Bash({shape}:*)"


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
        entry["command_shape"] = command_shape(input_text)[0]
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

    if tool_name == "Bash":
        cmd = tool_input.get("command", "")
        if not cmd:
            return None
        return "bash", cmd, None

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
    muted = load_session_mutes(data.get("session_id"))

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
        blocks, asks = evaluate_rules(config, input_kind, input_text, file_extension, cwd, muted)
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

    # Log the canonical plain text; render hyperlinks only in the prompt.
    _log_event(data, input_kind, input_text, decision, [_message_plain(v) for v in chosen])

    if decision != "allow":
        # Only the ask prompt renders OSC 8: Claude Code's error renderer (the
        # deny path) strips the escape without making it clickable, which would
        # drop the ref entirely. So deny keeps the plain `— <url>` form.
        hyperlinks = decision == "ask" and _hyperlinks_enabled()
        reason = "\n".join(_message_display(v, hyperlinks) for v in chosen)
        # Claude Code tags ask prompts with the source plugin but leaves deny
        # errors unattributed, so append the tag ourselves on the deny path to
        # match — the user should always see which plugin made the call.
        if decision == "deny":
            reason += f" {_PLUGIN_TAG}"
        # Teach the mute affordance at the point of friction ([MUTE-08]): a
        # display-only hint naming the mute command for the matched ask rules.
        # It is appended after `_log_event` above, so it never reaches the log.
        if decision == "ask":
            # Dedup while preserving order: two matched ask rules can share a
            # rule name (same `name` in different sets), which would otherwise
            # repeat the token in the suggested command.
            seen, tokens = set(), []
            for v in chosen:
                t = v.get("mute_token")
                if t and t not in seen:
                    seen.add(t)
                    tokens.append(t)
            if tokens:
                quoted = " ".join(shlex.quote(t) for t in tokens)
                reason += "\n\nMute for this session: /ClaudeWatch:mute " + quoted
        _emit(decision, reason)

    sys.exit(0)


if __name__ == "__main__":
    main()
