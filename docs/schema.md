# Rules YAML Schema

This is the reference for the **claude-watchdog** rules file format. Each YAML file is a self-contained rule set that the watchdog engine (`scripts/watchdog.py`) evaluates independently.

## Overview

```yaml
name: <string>           # required — rule set identity
filter: '<regex>'         # optional — pre-filter for fast skipping

rules:
  block:                  # rules that reject the command outright
    - name: <string>
      pattern: '<regex>'
      reason: <string>
      ref: <url>

  ask:                    # rules that require user confirmation
    - name: <string>
      pattern: '<regex>'
      except: '<regex>'   # optional — skip this rule if except matches
      reason: <string>
      ref: <url>
```

## Top-level fields

### `name` (required)

Identity of the rule set. Used as the label prefix in block/ask messages shown to the user.

```yaml
name: watch-git
```

When a rule fires, the message format is:

```
<name> — <reason> — <ref>
```

For example: `watch-git — overwrites shared remote history — https://git-scm.com/docs/git-push#...`

### `filter` (optional)

A Python regex applied to the command **before** any rules are checked. If the command does not match the filter, the entire rule set is skipped — no rules are evaluated.

```yaml
filter: '\bgit\b'
```

This is a performance optimization. Without it, every Bash command would be checked against every rule pattern. Use a broad filter that matches the domain of commands your rules care about.

If omitted, all Bash commands are evaluated against the rules.

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

Python regex matched against the full Bash command string using `re.search()`. This means the pattern matches **anywhere** in the command — you do not need to anchor it with `^` or `$` unless you specifically want to.

```yaml
pattern: 'git\s+push\s.*(--force|-[a-zA-Z]*f\b)'
```

This is the core safety advantage over Claude Code's built-in deny rules, which use `startsWith()` and miss compound commands like `git add . && git commit`.

**Pattern tips:**

- Use `\s+` instead of literal spaces to handle multiple spaces
- Use `\b` for word boundaries to avoid false positives
- Use `(\s|$)` to match "command with args or command alone"
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

## Hook wiring

A single `PreToolUse` hook points the engine at the `rules/` directory. The engine auto-discovers all `*.yml` files, evaluates every rule set, and returns a single coalesced decision:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.py ${CLAUDE_PLUGIN_ROOT}/rules"
          }
        ]
      }
    ]
  }
}
```

## Hook protocol

Claude Code sends tool invocations as JSON on stdin:

```json
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "git push --force origin main"
  }
}
```

The watchdog engine outputs one of:

| Decision | Output | Effect |
| --- | --- | --- |
| **block** | `{"decision":"block","reason":"..."}` | Command is rejected |
| **ask** | `{"decision":"ask","message":"..."}` | User is prompted to confirm |
| **allow** | *(no output)* | Command proceeds |

Exit code is always `0`.

Non-`Bash` tool invocations and empty commands are silently allowed.

## Creating a new rule set

To create a new rule set (e.g. `watch-docker`):

1. Create `rules/watch-docker.yml`:

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
      pattern: 'docker\s+run(\s|$)'
      except: 'docker\s+run\s+--rm\b'
      reason: starts a new container
      ref: https://docs.docker.com/reference/cli/docker/container/run/
```

2. Add tests to `tests/test-watchdog.sh` (follow the existing pattern).

The engine auto-discovers all `*.yml` files in `rules/`, so no changes to `hooks.json` are needed. To disable a rule set without deleting it, rename it to `*.yml.disabled`.
