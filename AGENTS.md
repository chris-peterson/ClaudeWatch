# AGENTS.md — Working on ClaudeWatch

This is the build philosophy and key constraints document for ClaudeWatch.
The contract lives in [`SPEC.md`](SPEC.md); this document captures the *how to
think about it*. Every Claude Code session should read this before making
non-trivial changes.

## What ClaudeWatch is

A Claude Code plugin that wraps every shell invocation — `Bash` and `Monitor`,
which runs its command in the same shell — in a `PreToolUse` hook and applies
regex-based safety rules. The core safety advantage over Claude
Code's built-in deny rules is that patterns match **anywhere** in the command
string (`re.search()`), so compound commands (`git add . && git push --force`),
heredocs, and reordered flags are not bypassable by syntactic tricks.

## Core contracts (don't break these)

1. **Determinism.** Given the same command, the same `cwd` and project root, the
   same `watches/` tree, and the same on-disk state of the paths those name, the
   engine must always produce the same *decision*.
   No clocks, no randomness, no network on the decision path. `cwd` and
   `CLAUDE_PROJECT_DIR` enter the decision only as the deterministic per-invocation
   inputs the `is_in_project_tree` predicate ([RL-15], [RL-16]) resolves `rm`
   targets against — pure string work, no filesystem access. `CLAUDE_PROJECT_DIR`
   is the one environment variable on the decision path; `CLAUDEWATCH_LOG`
   governs a side channel only. The one predicate that does read the filesystem
   is `is_recoverable` ([RL-18]), which asks git whether a delete target could
   be restored — a question with no textual answer. Its calls are
   read-only, bounded, and fail closed, so the decision stays a function of the
   command, the roots, and the on-disk state those name; a *second* predicate
   wanting filesystem access is a spec change, not a local call.
   Decision logging (on by default, see
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
4. **The engine ships self-contained.** `scripts/watchdog.py` and everything on
   the decision path use only the Python standard library (with a minimal
   built-in YAML parser), so the plugin installs cleanly and evaluates rules
   fast in any environment Claude Code runs in — no pip step on the hot path.
   Build- and release-time tooling that never runs on the decision path (e.g.
   shipyard's `gen-plugin-json`, run by CI's project job) may use PyYAML; it
   never runs in the hook.
5. **Allow-by-default.** When no rule matches, the engine produces no stdout
   output. Silence is allow.

## Build philosophy

- **The engine is generic; the rules are domain-specific.** Treat
  `scripts/watchdog.py` as a stable library. New safety domains are new YAML
  files in `watches/`, not new code.
- **`unless_condition` predicates are the one exception, so keep them thin.**
  A predicate answers something a regex cannot — "does this path resolve inside
  the tree" — so it is domain logic living in the engine, and adding one *is* an
  engine change with a spec requirement behind it. Push everything that isn't
  the domain judgment down into a shared helper: `_command_operands` parses
  POSIX utility syntax and takes the program as an argument, so a predicate for
  a different destructive tool reuses it rather than writing a second tokenizer
  that drifts from its guards. A predicate that has grown its own parsing is
  the signal that something belongs in the shared layer.
- **Make adding a rule set frictionless.** Drop a `watch-*.yml` file, add a
  test file, regenerate docs. No registration, no manifest, no engine change.
- **Rules are documentation.** Every rule has a `reason` and (almost always) a
  `ref` URL. The canonical message is `<rule>: <reason> — <ref>`, used verbatim
  in the prompt and the log alike; the rule-set name is omitted since the `ref`
  URL supplies it. If you can't articulate why a rule exists, don't add it.
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
  `watches/watch-<name>.yml`.
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
- **New or changed rule set** — Add/edit `watches/watch-<name>.yml` and
  `tests/test-watch-<name>.sh`. No `hooks.json` change needed (auto-discovery).
  A rule set is described in hand-maintained indexes that drift
  independently — update whichever the change affects:
  1. `README.md` — rule-sets table (one row per set)
  2. `SPEC.md` `[SH-01]` — enumeration with block/ask coverage prose

  The `docs/_site` reference is generated, not hand-maintained — run `just docs`.
  A dev-time PostToolUse hook (`.claude/settings.json` →
  `.claude/hooks/remind-rules-index.py`) emits this same checklist after any
  `watches/watch-*.yml` Write/Edit so it isn't forgotten; it is not part of the
  shipped plugin.
- **Spec changes** — Update `SPEC.md` first. If a code change reveals a spec
  problem (ambiguity, missing requirement), **note it** and resolve via the
  Gap Resolution Protocol (see the spec-driven recipe), don't silently change
  the implementation.

## plugin.yml is canonical

`plugin.yml` (repo root) is the single source of truth for the plugin's
descriptor. `.claude-plugin/plugin.json` is **generated** from it — don't
hand-edit `plugin.json`. The `suite:` block also feeds the bridge.ai
marketplace SPA.

**CI is the only writer.** `.github/workflows/project.yml` runs shipyard's
`project` action on every push, which regenerates `plugin.json`, `hooks.json`,
and `plugin.yml`'s `suite.describe` block from their sources and commits the
result straight back to the branch — so a committed artifact matches its
source at all times, and the diff a reviewer approves is the change that
lands. Editing `plugin.yml`, `hooks/hooks.yml`, a skill, or a rule needs no
local regeneration step; push, and the projection job's commit is what shows
up next.

To see what the projection job would write without keeping it — useful when
debugging a red run — use `just check`, then `git restore .` to discard.

`release.yml` resyncs the generated artifacts once more as a backstop when it
cuts a release, so `plugin.json` at a release tag is current even on the rare
run where the project job didn't land first.

## Releasing

Releasing is one `workflow_dispatch` on `.github/workflows/release.yml` whose
only input is the bump level (`patch`, `minor`, `major`).

Write the notes before dispatching — reading what landed is what tells you the
bump, so the two are one judgment:

```bash
git log $(git describe --tags --abbrev=0)..main --no-merges
```

Commit that section under `## Unreleased` in `CHANGELOG.md`, then dispatch
with the bump level the notes imply. A missing or empty `## Unreleased`
section fails the run.

Dispatching triggers shipyard's reusable release workflow, which:

1. derives the next version from `plugin.yml`,
2. retitles `CHANGELOG.md`'s `## Unreleased` section to that version,
3. resyncs the generated artifacts as a backstop (the project job already
   committed them when the source changed, so this ordinarily finds nothing to
   resync),
4. commits the bump, then tags that commit — so `plugin.json` at the tag
   reports the version the tag names,
5. publishes the GitHub Release from the section it just wrote, and
6. notifies the bridge.ai marketplace to rebuild its catalog via
   `repository_dispatch`.

`main` is always the latest released state, and `version` in `plugin.yml`
stays the source of truth — but it's now *written by* the release rather than
hand-edited. The chris-peterson marketplace tracks ClaudeWatch as an unpinned
git source (default-branch HEAD), so step 4's commit to `main` is the moment
consumers see the update; the tag and the marketplace notify are not what
`claude plugin update` reads.

## Known constraints (do not paper over)

- **macOS-style absolute paths** appear in shipped rules (`~/.ssh/...`,
  `~/.aws/credentials`). These are user-home patterns, not platform-specific
  per se — but the documentation references unix conventions. If
  cross-platform support becomes a goal, that's a spec change, not a quick
  fix.
- **YAML parser is minimal.** It handles the format ClaudeWatch ships and
  nothing more. Multi-line strings, anchors, and `!!tag` constructs are not
  supported. If you need them, that's a spec discussion, not a copy-paste of
  PyYAML.
- **Word normalization ([EN-15]) reaches the spellings that survive as a
  literal word**, not obfuscation in general. `"git" commit`, `g\it commit` and
  `git "commit"` all resolve to `git commit` before matching; a word assembled
  at runtime does not, because nothing in the command text says what it will
  be — `C=git; $C commit` is the shape to expect. A shell has unbounded ways to
  spell a word, so treat the rules as a guard against the destructive command
  an agent writes plainly, not as a sandbox against one trying to get past it.

## Reading order for new contributors

1. `README.md` — the elevator pitch and install path
2. `SPEC.md` — the contract
3. `scripts/watchdog.py` — the engine (under 250 lines)
4. `watches/watch-git.yml` — the canonical rule-set example
5. `SCHEMA.md` — the YAML rule format reference (for rule authors)
6. `tests/test-watch-git.sh` — the test pattern
7. This file — for "how to think about adding things"
