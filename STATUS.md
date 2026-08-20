# ClaudeWatch — Spec Coverage Status

Tracking status of the requirements declared in [SPEC.md](SPEC.md). Updated
whenever an audit (`/spec-audit`) is run, when implementation lands, or when
the spec is revised.

**Last audit:** 2026-06-22
**Spec version:** v1 (root SPEC.md, no versioned tree)
**Coverage:** 84/84 normative requirements (100%) + 3 deferred targets (FUT-01..FUT-03).
FUT-04..FUT-06 are deferred-discussion notes (rule-edit durability across upgrades,
repo-scoped git trust, per-repo self-marketplace), not numbered targets.

Evidence below points to the authoritative source for each cluster — SPEC.md
for the contract, `scripts/watchdog.py` for engine behavior, and the per-set
`tests/test-watch-*.sh` / `tests/test-engine.sh` for executable verification.
Specific line numbers are given only where a single requirement pins to one
spot; broader clusters cite the file and its tests.

## Status table

| ID | Requirement | Status | Evidence |
|----|-------------|--------|----------|
| EN-01..EN-13 | Engine lifecycle, IO, tool dispatch, error handling | Covered | `scripts/watchdog.py` + `tests/test-engine.sh` |
| EN-04a | Log JSON parse error to stderr | Covered | `scripts/watchdog.py:335` |
| EN-05a | No-arg fallback to `../watches` | Covered | `scripts/watchdog.py:343-346` |
| LOG-01..LOG-06 | Decision logging side channel: on by default (`CLAUDEWATCH_LOG=off` to opt out), records the command shape rather than the raw command, owner-only perms (0600/0700), schema-versioned header that discards pre-shape logs on upgrade | Covered | `scripts/watchdog.py` (`_log_event`, `command_shape`) + `tests/test-logging.sh` |
| RS-01..RS-08 | Rule set format, discovery, `extensions` gating | Covered | `scripts/watchdog.py` + `tests/test-engine.sh` |
| RL-01..RL-14 | Rule fields, `target`, evaluation order, error handling, unrecognized-field warning | Covered | `scripts/watchdog.py` + `tests/test-engine.sh` |
| OUT-01..OUT-05, OUT-07, OUT-08 | Output decisions, formatting, aggregation, allow-by-default, deny source tag, compound-command ask→deny escalation | Covered | `scripts/watchdog.py` + `tests/test-engine.sh` + `tests/test-output.sh` |
| OUT-06 | Ref rendered as an OSC 8 hyperlink *(retired in 0.18.0)* | Removed | Claude Code 2.1.235 replaces control characters in a hook's reason with U+FFFD |
| HK-01 | PreToolUse hooks for Bash/Write/Edit | Covered | `hooks/hooks.json` |
| HK-02 | SessionStart hook (no-op placeholder) | Covered | `hooks/hooks.json`, `hooks/cli-freshness.sh` |
| HK-03 | Hooks declared in hooks.json | Covered | `hooks/hooks.json` |
| HK-04 | SessionStart ambient guidance emission | Covered | `hooks/emit-rules.sh`, `rules/*.md`, `tests/test-ambient.sh` |
| EXT-01..EXT-03 | Auto-discovery, disable-by-rename, no-code-change | Covered | `scripts/watchdog.py`, `tests/test-engine.sh` |
| SK-01 | `/ClaudeWatch:help` overview *(retired in 0.16.0)* | Removed | README + docs site |
| SK-02..SK-12 | `/ClaudeWatch:rules` interactive editor | Covered | `skills/rules/SKILL.md` |
| SK-13..SK-17 | `/ClaudeWatch:learn` decision-log analysis | Covered | `skills/learn/SKILL.md`, `scripts/analyze-decisions.py` |
| DOC-01, DOC-02, DOC-04, DOC-05 | Docsify site, `just docs` regen (rules + prompts pages), YAML schema reference | Covered | `docs/`, `SCHEMA.md`, `build/gen-rules-doc.py`, `justfile` |
| DIST-01 | Expose install metadata in manifest | Covered | `.claude-plugin/plugin.json` (name, version, description, repository, license) — hosting/marketplace mechanism is out of scope per SPEC.md |
| DIST-02 | `.claude-plugin/plugin.json` manifest | Covered | `.claude-plugin/plugin.json` |
| DIST-03 | Runnable via `claude --plugin-dir .` | Covered | `justfile` (`just try`) |
| SH-01 | Shipped rule sets (enumerated) | Covered | `watches/*.yml` + per-set `tests/test-watch-*.sh` |
| SH-02 | Filter regex on bash-target rule sets | Covered | All shipped `watches/*.yml` declaring `target: bash` rules |
| SH-03 | `ref` URLs on rules | Covered | All shipped `watches/*.yml` |
| SH-04 | Per-set test files | Covered | `tests/test-watch-*.sh` |
| DEV-01..DEV-04 | `just test`, test layout, `just rules`, `just docs-preview` | Covered | `justfile` + `tests/` |
| FUT-01 | SessionStart self-check | Deferred | `hooks/cli-freshness.sh` is intentional no-op |
| FUT-02 | `new` rule-set scaffolds a test file | Deferred — partially covered | `skills/rules/SKILL.md` already offers this; consider promoting |
| FUT-03 | Multi-line YAML strings / anchors | Deferred | Not needed by current rules |

## Audit history

### 2026-06-22 — Coverage refresh (spec-status)

STATUS.md updated: +2 IDs (LOG-05 owner-only log perms, LOG-06 schema-versioned log with discard of pre-shape logs on upgrade), normative count 83 → 85. Shipped alongside the shape-only decision-log change ([LOG-03] now records the command shape, not the raw command).

### 2026-06-22 — Coverage refresh (spec-status)

STATUS.md updated: +1 ID (OUT-08, compound-command ask→deny escalation), normative count 82 → 83. Shipped alongside the [OUT-08] engine change for issue #14.

### 2026-05-31 — Coverage reconciliation

Re-audited against the current 85-ID SPEC.md. The status table had drifted
behind the spec; reconciled the following:

- Removed phantom requirement IDs that no longer exist in SPEC.md: **SH-01a**
  and **SH-04a** (their content was folded into the SH-01 / SH-04 prose), and
  **DOC-03** (DOC is now only 01 / 02 / 04).
- Added rows for spec sections that had landed since the last audit but were
  missing from the table: EN-12/EN-13 (Write/Edit dispatch), LOG-01..LOG-04
  (decision logging), RS-07/RS-08 (`extensions` gating), RL-10..RL-13
  (`target` field), and SK-13..SK-17 (`/ClaudeWatch:learn`).
- Corrected **DIST-01** wording from "marketplace install" to "expose install
  metadata in manifest"; marketplace registration is out of scope per the
  DIST-01 text.
- Re-pointed stale evidence line numbers (EN-04a `:166-168` → `:335`, EN-05a
  `:177-180` → `:343-346`) and collapsed broader clusters to cite SPEC.md plus
  the per-set / engine tests rather than brittle line ranges.

### 2026-05-08 — Initial bootstrap audit

Spec was drafted retroactively from the implementation, then audited. Findings
applied this session:

- **Spec edits (SPEC.md)**
  - SH-02 rewritten to enumerate the 5 shipped block rules and 11 ask rules
    (dropped fictional `sudo apt`, added `wget|sh`, `brew install`, `pnpm`,
    `cargo`, `go`, `gem`, `composer`, `npx`).
  - SH-03 rewritten to include `rm -rf /*`, `rm -r`, `mv /`, and the cache/tmp
    `except` whitelist.
  - SH-04 rewritten to enumerate all 7 ask rules (PEM/key reads, secret-name
    file reads, export-secret-inline, `.env`, etc.).
  - Added SH-01a (git pre-subcommand-flag handling) — promotes a security-
    relevant regex pattern to a normative requirement. (Later folded into the
    SH-01 prose; SH-01a is no longer a separate ID.)
  - Added SH-04a (shell-command boundaries on full-token rules). (Later folded
    into the SH-04 prose; SH-04a is no longer a separate ID.)
  - Added EN-04a (stderr logging on JSON parse failure).
  - Added EN-05a (explicit no-arg fallback to `../watches`).
  - SK-05 expanded to enumerate all 7 edit operations including `<id>:allow`
    and `<id>:ask`.

- **Code edits**
  - `scripts/watchdog.py`: log JSON parse errors to stderr (EN-04a).
  - `.claude-plugin/plugin.json`: fix description typo
    (`enforce` → `enforces`, `claude-watches` → `claude-watchdog`).
  - `AGENTS.md`: fix cross-reference typo (`SH/FUT-01` → `FUT-01`).

- **Open items (not addressed this pass)**
  - Engine no-arg fallback (`scripts/watchdog.py:177-180`) is now spec'd via
    EN-05a rather than removed. The user's `no-fallbacks` rule prefers loud
    failure; reconsider if the fallback ever masks a real misconfiguration.
  - FUT-02 (`new` scaffolds a test file) is partially implemented and could
    be promoted to a normative SK requirement on next pass.

## How to use this file

When you implement a new requirement, change the row's status to **Covered**
and add an evidence pointer. When an audit reveals drift, update the row's
status to **Partial** or **Contradicts** with a one-line note. New
requirements added to SPEC.md should appear here on the next audit.
