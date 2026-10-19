# CLAUDE.md

Shared agent guidance lives in [`AGENTS.md`](AGENTS.md), imported below. This
file holds Claude Code–specific bits.

@AGENTS.md

## Commands

```bash
# Run tests
bash tests/test-watchdog.sh

# Test the plugin locally
claude --plugin-dir .
```

## Hook protocol

Claude Code passes tool invocations as JSON on stdin. The hook outputs
`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny|ask","permissionDecisionReason":"..."}}`
to reject or prompt the user, or nothing (allow). Exit code must always be 0,
and every error the engine sees becomes a `deny`; errors outside the engine
(no `python3`, a timeout) block the call through the hooks' `onFailure: block`
(see [`AGENTS.md`](AGENTS.md) "Core contracts").
