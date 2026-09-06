# Rules YAML Schema

This is the reference for the **claude-watchdog** rules file format. Each YAML file is a self-contained rule set that the watchdog engine (`scripts/watchdog.py`) evaluates independently.

## Overview

```yaml
name: <string>                # required — rule set identity
filter: '<regex>'              # optional — pre-filter for bash-target rules
extensions: ['.ext', ...]      # optional — gates file-content-target rules by file extension

rules:
  block:                       # rules that reject the command outright
    - name: <string>
      pattern: '<regex>'
      target: bash | file-content  # optional
      reason: <string>
      ref: <url>

  ask:                         # rules that require user confirmation
    - name: <string>
      pattern: '<regex>'
      target: bash | file-content  # optional
      except: '<regex>'        # optional — skip this rule if except matches
      unless_condition: [name] # optional — skip this rule if a named predicate matches
      unless_regex: ['<regex>'] # optional — skip this rule if any listed regex matches
      reason: <string>
      ref: <url>
```

## Top-level fields

### `name` (required)

Identity of the rule set. Used as the label prefix in block/ask messages shown to the user.

```yaml
name: watch-git
```

When a rule fires, the canonical message format is:

```text
<rule>: <reason> — <ref>
```

For example: `git push --force: overwrites shared remote history — https://git-scm.com/docs/git-push#...`

The rule-set name (`watch-git`) is left out — the `ref` URL supplies that context. Ask prompts, deny errors, and the decision log all carry this same form. A deny message additionally ends with a ` [plugin:ClaudeWatch]` source tag, which Claude Code supplies itself on ask prompts.

### `filter` (optional)

A Python regex applied to the bash command **before** any `target: bash` rules are checked. If the command does not match the filter, those rules are skipped. The filter does **not** gate `target: file-content` rules — those are gated by `extensions`.

```yaml
filter: '\bgit\b'
```

This is a performance optimization. Without it, every Bash command would be checked against every rule pattern. Use a broad filter that matches the domain of commands your rules care about.

If omitted, all bash-target rules are evaluated against every Bash command.

### `extensions` (optional)

An inline list of file extensions (including the leading dot) that gates `target: file-content` rules. When the engine handles a `Write` or `Edit` invocation, it skips the rule set entirely unless the target file's extension matches one of the listed values. Matching is case-insensitive.

```yaml
extensions: ['.ps1', '.psm1', '.psd1']
```

If omitted, the rule set's `target: file-content` rules are never evaluated. Bash-target rules are unaffected.

### `rules` (required)

Contains two lists: `block` and `ask`. Both are optional (you can have a rule set with only `block` rules, or only `ask` rules).

**Evaluation order:**

1. All `block` rules are checked first, in order. First match wins — the command is rejected.
2. If no block rule matches, all `ask` rules are checked in order. For each matching ask rule, if `except` is set and matches the command, that rule is skipped. First non-excepted match wins — the user is prompted.
3. If nothing matches, the command is allowed silently.

## Rule fields

Each rule in a `block` or `ask` list has these fields:

### `name` (required)

Human-readable label for the rule, shown in tables and skill UIs.

```yaml
name: git push --force
```

### `pattern` (required)

Python regex matched against the input string using `re.search()`. This means the pattern matches **anywhere** — you do not need to anchor it with `^` or `$` unless you specifically want to. The input string depends on the rule's `target`:

- `target: bash` — the full Bash command string (the default if `target` is omitted).
- `target: file-content` — the body of the file being written or edited. For `Edit`, this is the full post-edit content (the on-disk file with `old_string` replaced by `new_string`).

```yaml
pattern: 'git\s+push\s.*(--force|-[a-zA-Z]*f\b)'
```

This is the core safety advantage over Claude Code's built-in deny rules, which use `startsWith()` and miss compound commands like `git add . && git commit`.

**Pattern tips:**

- Use `\s+` instead of literal spaces to handle multiple spaces
- Use `\b` for word boundaries inside a token; for the token's own edges see the two bullets below, which the shell's own boundaries govern
- Write the program and subcommand as bare words — a `bash` input arrives with the leading words of each command already unquoted ([EN-15]), so `git commit` matches `"git" commit` and `git "commit"` without the pattern saying so, while operands keep their quoting
- End a bare subcommand with `(?=$|[\s;&|)`<>])`, which is where the shell ends it. `(\s|$)` looks equivalent and isn't: a command alone is followed by whatever comes next, so `(git push)`, `git push;echo done` and `` `git push` `` slip past it. Match the terminators rather than excluding the continuations — `(?![\w-])` also accepts a closing quote, so it fires on `grep -rn 'git push' .`
- Bound a bare program name with `(?:^|[\s;&|`(])` rather than `\b`, so a hyphenated name (`my-rm`) is not read as the program it ends with
- Use negative lookahead `(?!...)` to exclude variants (e.g. `git\s+rm\b(?!.*--cached)`)
- Remember `re.search()` matches anywhere — `git\s+push` will match both `git push` and `git add . && git push`

### `reason` (required)

Short explanation of **why** the rule exists. Shown to the user in the block/ask message.

```yaml
reason: overwrites shared remote history
```

### `ref` (optional)

URL to relevant documentation. Shown at the end of the block/ask message. Can be empty string or omitted.

```yaml
ref: https://git-scm.com/docs/git-push#Documentation/git-push.txt--f
```

### `target` (optional)

Selects which engine input the rule's `pattern` runs against. Values:

- `bash` (default) — match against the Bash command string.
- `file-content` — match against the body of a file being authored via `Write` or modified via `Edit`. Requires the rule set to declare `extensions` listing applicable file extensions; otherwise the rule is never evaluated.

A single rule set may mix bash-target and file-content-target rules. For example, `watch-pwsh.yml` ships both inline-script rules (run against `pwsh -Command "..."` bash invocations) and file-content rules (run against `.ps1`/`.psm1`/`.psd1` script bodies).

Any value other than `bash` or `file-content` causes the engine to emit a `deny` decision naming the rule.

### `except` (optional, ask rules only)

A Python regex that exempts matching commands from this rule. If `except` matches the command, the rule is skipped even though `pattern` matched. This reduces prompt noise for known-safe patterns without weakening block rules.

```yaml
- name: rm -rf
  pattern: 'rm\s+-[a-zA-Z]*r[a-zA-Z]*f'
  except: 'rm\s+(-[a-zA-Z]+\s+)*(~/\.cache/|/tmp/|/var/tmp/)'
  reason: recursively deletes files and directories
  ref: https://man7.org/linux/man-pages/man1/rm.1.html
```

Using `except` on a `block` rule emits a warning and is ignored — block rules always fire.

### `unless_condition` / `unless_regex` (optional, ask rules only)

Two inline-list fields that exempt an ask rule, OR'd together: the rule is skipped when **any** `unless_regex` entry matches the command, or **any** `unless_condition` predicate matches. Both apply only to `ask` rules; on a `block` rule they emit a warning and are ignored.

```yaml
- name: rm -r
  pattern: 'rm\s+-[a-zA-Z]*r'
  unless_condition: [is_in_project_tree]
  unless_regex: ['rm\s+(-[a-zA-Z]+\s+)*(~/\.cache/|/tmp/|/var/tmp/)']
  reason: recursively deletes directories
  ref: https://man7.org/linux/man-pages/man1/rm.1.html
```

**`unless_regex`** is a list of regexes — the same exemption `except` provides, but as a list (and `except` remains supported for the single-regex case). List items may be quoted or bare; commas inside a quoted item are preserved, so a regex quantifier like `{1,2}` is safe.

**`unless_condition`** is a list of **named predicates** the engine ships — richer than a regex because a predicate can reason about the command's structure and the hook's `cwd`. An unknown name surfaces as a config-error `deny` (it never silently fails to match). Predicates apply to bash input only.

Available predicates:

| Predicate | Skips the ask when… |
| --- | --- |
| `is_in_project_tree` | every deletion target of an `rm` command resolves **strictly under an anchor root** — the session's working directory (the `cwd` Claude Code passes at the top level of the hook input) or the project root (`CLAUDE_PROJECT_DIR`, which Claude Code exports to hook commands). The premise: an in-tree recursive delete is recoverable from git history, so it need not prompt, while one reaching outside the tree still does. |
| `is_ephemeral_scratch` | every deletion target of an `rm` command **names a regenerable tool directory** — `.playwright-mcp`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`. The premise is the directory's identity rather than its location: deleting one loses nothing that re-running the tool doesn't reproduce, so it need not prompt wherever on disk it sits. |
| `is_recoverable` | every deletion target is **both** under an anchor root **and** restorable from git — the target is tracked, isn't a submodule, and holds no file that is untracked, ignored, or edited without being committed. Where `is_in_project_tree` assumes location implies recoverability, this checks it, so a workspace root that isn't itself a repo no longer exempts a delete with no history behind it. Unlike the other two it reads the filesystem, via bounded read-only `git` calls that decline the exemption whenever a check can't complete. Git is the only backend; for a location some other tool can restore, use `unless_regex` on the path. No shipped rule uses it. |

Two roots rather than one because `cwd` follows the session's shell — it leaves the project the moment the session changes directory into a scratch area, and an in-repo delete issued from there is no less recoverable for it. The project root holds still. A **relative** target resolves against `cwd` only (that is what the shell itself would do); an **absolute** target may sit under either root. `/` and the user's home directory are rejected as roots — a delete anywhere beneath either is not what "confined to the working tree" means.

`is_in_project_tree` is deliberately conservative — it declines (and the ask stands) whenever in-tree-ness can't be proven from the command text alone:

- there is no usable root (no `cwd` and no `CLAUDE_PROJECT_DIR`, or only rejected ones);
- the command is compound (a pipe/chain/`;`/substitution) — those are handled by the compound-command escalation instead;
- the program is not `rm`, or the command has no deletion targets;
- a target is an anchor root itself (`.`) or a `.git` directory — the git-history safety net doesn't cover wiping the whole tree or its history;
- a target carries an unresolvable marker: `~` (home), `$`/backtick (variable or command substitution), a glob (`*`, `?`, `[`), or a `..` segment that could escape the tree;
- a target is an absolute path, or a relative path, that resolves outside every root.

`is_ephemeral_scratch` matches on the **final path segment** only, so `rm -rf .playwright-mcp/traces` is not exempt — the exemption can't be widened by appending a subdirectory — and it declines on the same compound-command, parse-failure, non-`rm`, no-target, and unresolvable-marker conditions, so a glob or variable can never stand in for the name.

Both analyses are pure string resolution (no filesystem access), so the decision stays deterministic — symlinked targets are classified by their textual path, not their link destination.

## Hook wiring

Two `PreToolUse` hooks point the engine at the `watches/` directory — one for `Bash|Monitor`, one for `Write|Edit`. The engine auto-discovers all `*.yml` files, evaluates every rule set, and returns a single coalesced decision:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Monitor",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.py ${CLAUDE_PLUGIN_ROOT}/watches"
          }
        ]
      },
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.py ${CLAUDE_PLUGIN_ROOT}/watches"
          }
        ]
      }
    ]
  }
}
```

## Hook protocol

Claude Code sends tool invocations as JSON on stdin. The engine handles these tool names:

```json
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "git push --force origin main"
  }
}
```

`Monitor` carries the same `command` field and runs it in the same shell, so it is matched against `target: bash` rules exactly as `Bash` is. A `Monitor` call that carries a `ws` object instead of a `command` has nothing to screen and is allowed.

```json
{
  "tool_name": "Monitor",
  "tool_input": {
    "command": "while true; do git commit -m wip; sleep 30; done"
  }
}
```

```json
{
  "tool_name": "Write",
  "tool_input": {
    "file_path": "cleanup.ps1",
    "content": "Remove-Item -Recurse -Force /tmp/x"
  }
}
```

```json
{
  "tool_name": "Edit",
  "tool_input": {
    "file_path": "helper.py",
    "old_string": "return 1",
    "new_string": "return eval(formula)",
    "replace_all": false
  }
}
```

For `Edit`, the engine reads the on-disk file, applies the `old_string` → `new_string` substitution (all occurrences if `replace_all` is true), and matches `target: file-content` rules against the resulting full content. If the file cannot be read, the engine falls back to matching `new_string` alone.

The watchdog engine outputs one of:

| Decision | Output | Effect |
| --- | --- | --- |
| **block** | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}` | Tool call is rejected |
| **ask** | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"..."}}` | User is prompted to confirm |
| **allow** | *(no output)* | Tool call proceeds |

Exit code is always `0`.

Tool invocations other than `Bash`, `Monitor`, `Write`, `Edit` (and empty payloads) are silently allowed.

## Creating a new rule set

To create a new rule set (e.g. `watch-docker`):

1. Create `watches/watch-docker.yml`:

```yaml
name: watch-docker
filter: '\bdocker\b'

rules:
  block:
    - name: docker system prune
      pattern: 'docker\s+system\s+prune'
      reason: removes all unused data (containers, images, networks)
      ref: https://docs.docker.com/reference/cli/docker/system/prune/

  ask:
    - name: docker run
      pattern: 'docker\s+run(?![\w-])'
      except: 'docker\s+run\s+--rm\b'
      reason: starts a new container
      ref: https://docs.docker.com/reference/cli/docker/container/run/
```

2. Add tests to `tests/test-watchdog.sh` (follow the existing pattern).

The engine auto-discovers all `*.yml` files in `watches/`, so no changes to `hooks.json` are needed. To disable a rule set without deleting it, rename it to `*.yml.disabled`.
