# AGENTS.md — Working on ClaudeWatch

This is the build philosophy and key constraints document for ClaudeWatch.
The contract lives in [`SPEC.md`](SPEC.md); this document captures the *how to
think about it*. Every Claude Code session should read this before making
non-trivial changes.

## What ClaudeWatch is

A Claude Code plugin that wraps every Bash invocation in a `PreToolUse` hook
and applies regex-based safety rules. The core safety advantage over Claude
Code's built-in deny rules is that patterns match **anywhere** in the command
string (`re.search()`), so compound commands (`git add . && git push --force`),
heredocs, and reordered flags are not bypassable by syntactic tricks.

## Core contracts (don't break these)

1. **Determinism.** Given the same command and the same `rules/` tree, the
   engine must always produce the same *decision*. No clocks, no randomness,
   no network on the decision path. Decision logging (on by default, see
   [LOG-01]–[LOG-04]; `CLAUDEWATCH_LOG=off` opts out) is a side channel: it
   stamps a timestamp and writes a file *after* the decision is computed, never
   feeding back into it. Keep it that way — the clock stays in `_log_event`, not
   in `evaluate_rules`.
2. **Exit code is always 0.** A non-zero exit blocks the host (Claude Code)
   from getting a useful decision. All errors are surfaced as `deny` decisions
   with explanatory messages.
3. **Single coalesced decision per invocation.** Multiple matching rules
   across multiple rule sets aggregate into one `deny` (preferred) or one
   `ask`. Never emit more than one decision.
4. **No third-party Python dependencies at runtime.** The engine ships with a
   minimal pure-Python YAML parser specifically so the hook works in any
   environment Claude Code can run in. PyYAML is *not* an acceptable
   dependency.
5. **Allow-by-default.** When no rule matches, the engine produces no stdout
   output. Silence is allow.

## Build philosophy

- **The engine is generic; the rules are domain-specific.** Treat
  `scripts/watchdog.py` as a stable library. New safety domains are new YAML
  files in `rules/`, not new code.
- **Make adding a rule set frictionless.** Drop a `watch-*.yml` file, add a
  test file, regenerate docs. No registration, no manifest, no engine change.
- **Rules are documentation.** Every rule has a `reason` and (almost always) a
  `ref` URL. The canonical message is `<rule>: <reason> — <ref>` (logged
  verbatim; the rule-set name is omitted since the `ref` link supplies it); in
  the prompt the `<reason>` prose itself is the clickable link to `<ref>` (see
  `[OUT-06]`). If you can't articulate why a rule exists, don't add it.
- **Block is for "no recovery"; ask is for "permanent but recoverable".**
  `git push --force` blocks (overwrites remote history). `git commit` asks
  (you can amend or reset). When in doubt, prefer `ask` — block rules are
  un-bypassable.
- **`except` is a noise filter, not a security exception.** `except` only
  applies to ask rules; block rules ignore it with a stderr warning. Use
  `except` to skip prompts on demonstrably-safe variants (`rm -rf /tmp/...`),
  not to make a block rule "softer."
- **Allow-by-default (deny-list) vs ask-by-default (allow-list).** Most sets
  are deny-lists: allow-by-default, enumerate the dangerous ops as block/ask —
  you don't want to prompt on every `git status`. Flip to an allow-list — one
  broad catch-all `ask` plus an `except` for the safe subset — only when the
  tool surface is huge and mostly consequential (a cloud control plane), the
  safe subset is small and cleanly identifiable (AWS `get-`/`list-`/`describe-`/
  `head-` verbs), and an un-prompted action is costly (spend, data loss, prod
  change). Litmus test: enumerate the small side. `watch-aws` is the allow-list
  example; `watch-git` is the deny-list example.

## Repo conventions

- One Python file (`scripts/watchdog.py`), one YAML format, one hook config
  (`hooks/hooks.json`). Resist refactoring into modules until there's a
  concrete reason — the simplicity is a feature.
- Tests are bash scripts that pipe JSON to the engine and assert decisions.
  Keep them readable and self-contained — `tests/test-watch-<name>.sh` mirrors
  `rules/watch-<name>.yml`.
- Docs are generated from rules YAML by `build/gen-rules-doc.py`. Don't
  hand-edit `docs/_site` content for rule references; edit the YAML and run
  `just docs`.

## When making changes

- **Rule edits** — Use `/ClaudeWatch:rules` for interactive edits; it
  validates and previews. Manual edits to YAML are fine for bulk changes,
  but run `just test` before committing.
- **Engine changes** — Update `scripts/watchdog.py` and `tests/test-engine.sh`
  in the same change. The engine has a small surface; every behavior should
  be exercised by a test.
- **New or changed rule set** — Add/edit `rules/watch-<name>.yml` and
  `tests/test-watch-<name>.sh`. No `hooks.json` change needed (auto-discovery).
  A rule set is described in three hand-maintained indexes that drift
  independently — update whichever the change affects:
  1. `README.md` — rule-sets table (one row per set)
  2. `SPEC.md` `[SH-01]` — enumeration with block/ask coverage prose
  3. `skills/help/SKILL.md` — rule-sets table (one-line summary)

  The `docs/_site` reference is generated, not hand-maintained — run `just docs`.
  A dev-time PostToolUse hook (`.claude/settings.json` →
  `.claude/hooks/remind-rules-index.py`) emits this same checklist after any
  `rules/watch-*.yml` Write/Edit so it isn't forgotten; it is not part of the
  shipped plugin.
- **Spec changes** — Update `SPEC.md` first. If a code change reveals a spec
  problem (ambiguity, missing requirement), **note it** and resolve via the
  Gap Resolution Protocol (see the spec-driven recipe), don't silently change
  the implementation.

## Releasing

Releases are cut by bumping `version` in `.claude-plugin/plugin.json` and adding
a matching `CHANGELOG.md` section, then merging to `main`. This project does
**not** use git tags or GitHub releases — don't create them, and don't check for
them to determine release state. The version in `plugin.json` is the source of
truth; the next release is `current + 1` (minor bump for features, patch for
fixes).

## Known constraints (do not paper over)

- **macOS-style absolute paths** appear in shipped rules (`~/.ssh/...`,
  `~/.aws/credentials`). These are user-home patterns, not platform-specific
  per se — but the documentation references unix conventions. If
  cross-platform support becomes a goal, that's a spec change, not a quick
  fix.
- **`SessionStart` hook is a no-op placeholder.** `hooks/cli-freshness.sh`
  exists for symmetry across the chris-peterson plugin namespace and to
  reserve a spot for future plugin-update self-checks. Do not delete it
  silently — see [FUT-01] in `SPEC.md`.
- **YAML parser is minimal.** It handles the format ClaudeWatch ships and
  nothing more. Multi-line strings, anchors, and `!!tag` constructs are not
  supported. If you need them, that's a spec discussion (see [FUT-03]),
  not a copy-paste of PyYAML.

## Reading order for new contributors

1. `README.md` — the elevator pitch and install path
2. `SPEC.md` — the contract
3. `scripts/watchdog.py` — the engine (under 250 lines)
4. `rules/watch-git.yml` — the canonical rule-set example
5. `tests/test-watch-git.sh` — the test pattern
6. This file — for "how to think about adding things"
