#!/usr/bin/env node
/*
 * analyze: turn a ClaudeWatch decision log into review proposals.
 *
 * Reads the JSONL written by the engine (watchdog.mjs; on by default unless
 * CLAUDEWATCH_LOG is off), groups records by command shape, cross-references the
 * current Claude Code allow list, and emits a structured proposal the
 * /ClaudeWatch:learn skill renders for batch approval.
 *
 * Node standard library only (node: built-ins); no npm deps. ESM.
 *
 * Three buckets:
 *   - allow_candidates  — commands ClaudeWatch allows that are NOT covered by an
 *                         allow rule in settings.json, so Claude Code prompts on
 *                         them. Promoting these to the allow list removes prompts.
 *   - except_candidates — commands ClaudeWatch repeatedly asks about. Candidates
 *                         for an `except` (if a safe variant) or for acceptance.
 *   - deny_summary      — commands ClaudeWatch blocked, grouped by reason.
 *                         Informational: a high count may mean a workflow you
 *                         need is blocked.
 *
 * Read-only, stdlib-only, no network. The allow-pattern match is an approximate
 * prefix check (Claude Code's own matcher is the source of truth); it exists only
 * to avoid re-proposing commands you already allow.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import process from "node:process";

// `commandShape` is defined in the engine (it writes the shape to the log per
// [LOG-03]); the analyzer imports it so writer and reader share one definition.
// Applying it to an already-logged shape is idempotent, so it also re-derives the
// allow pattern from a logged shape and reduces any legacy raw-command records.
import { commandShape } from "./watchdog.mjs";

const DEFAULT_LOG = "~/.claude/claudewatch/decisions.jsonl";
const DEFAULT_SETTINGS = "~/.claude/settings.json";

const DURATION_UNITS = { m: "minutes", h: "hours", d: "days", w: "weeks" };

function _expanduser(p) {
  // Match Python os.path.expanduser: expand a leading ~ from $HOME (or
  // USERPROFILE on Windows), so a sandboxed HOME in tests resolves correctly.
  if (!p.startsWith("~")) {
    return p;
  }
  const home =
    process.env.HOME ||
    process.env.USERPROFILE ||
    (process.env.HOMEDRIVE && process.env.HOMEPATH
      ? process.env.HOMEDRIVE + process.env.HOMEPATH
      : undefined) ||
    os.homedir();
  if (p === "~") {
    return home;
  }
  if (p[1] === "/" || p[1] === path.sep) {
    return home + p.slice(1);
  }
  return p;
}

class DurationError extends Error {}

function parseDuration(text) {
  // Parse '90m', '2h', '1d', '1w' into a milliseconds count.
  const m = /^(\d+)\s*([mhdw])$/.exec(text.trim());
  if (!m) {
    throw new DurationError(
      `invalid duration '${text}' (use forms like 90m, 2h, 1d, 1w)`,
    );
  }
  const n = parseInt(m[1], 10);
  const unit = DURATION_UNITS[m[2]];
  const perUnitMs = {
    minutes: 60 * 1000,
    hours: 60 * 60 * 1000,
    days: 24 * 60 * 60 * 1000,
    weeks: 7 * 24 * 60 * 60 * 1000,
  };
  return n * perUnitMs[unit];
}

function _parseIso(ts) {
  // Match the subset of datetime.fromisoformat the log uses: a +00:00 (or
  // millis/micros) offset suffix the engine writes. Returns a millisecond
  // epoch, or null when unparseable (Python raises ValueError, caught at the
  // call sites). JS Date parses offsets and Z; Python's fromisoformat does not
  // parse a trailing Z (pre-3.11), but the engine never writes Z — it writes
  // +00:00 — so the corpus stays within the parseable set.
  const d = new Date(ts);
  const t = d.getTime();
  return Number.isNaN(t) ? null : t;
}

function loadAllowPrefixes(settingsPath) {
  // Return a list of [prefix, raw_pattern] from settings.json Bash allow rules.
  // Converts `Bash(git push:*)` / `Bash(cat *)` into the literal prefix a command
  // must start with to be considered already-allowed.
  const p = _expanduser(settingsPath);
  let stat;
  try {
    stat = fs.statSync(p);
  } catch {
    return [];
  }
  if (!stat.isFile()) {
    return [];
  }
  const settings = JSON.parse(fs.readFileSync(p, "utf8"));
  const prefixes = [];
  const allow = (settings.permissions && settings.permissions.allow) || [];
  for (const rule of allow) {
    const m = /^Bash\((.*)\)$/.exec(rule);
    if (!m) {
      continue;
    }
    const inner = m[1];
    // Python re.split(r":\*|\*", inner, maxsplit=1)[0].rstrip()
    const split = inner.split(/:\*|\*/, 1);
    const prefix = split[0].replace(/\s+$/, "");
    prefixes.push([prefix, rule]);
  }
  return prefixes;
}

function isAlreadyAllowed(command, allowPrefixes) {
  for (const [prefix] of allowPrefixes) {
    if (prefix && command.startsWith(prefix)) {
      return true;
    }
  }
  return false;
}

class NotFoundError extends Error {}

function readRecords(logPath, cutoffMs) {
  // Return decision records from the log, optionally filtered to ts >= cutoff.
  const p = _expanduser(logPath);
  let stat;
  try {
    stat = fs.statSync(p);
  } catch {
    throw new NotFoundError(p);
  }
  if (!stat.isFile()) {
    throw new NotFoundError(p);
  }
  const records = [];
  const content = fs.readFileSync(p, "utf8");
  for (let line of content.split("\n")) {
    line = line.trim();
    if (!line) {
      continue;
    }
    let rec;
    try {
      rec = JSON.parse(line);
    } catch {
      continue;
    }
    if (rec && typeof rec === "object" && "schema" in rec && !("decision" in rec)) {
      continue; // the log's schema header ([LOG-06]), not a decision record
    }
    if (cutoffMs !== null) {
      const ts = rec.ts;
      if (ts) {
        const when = _parseIso(ts);
        if (when !== null && when < cutoffMs) {
          continue;
        }
      }
    }
    records.push(rec);
  }
  return records;
}

function summarizeWindow(records) {
  // Describe the slice of history the proposals are drawn from: distinct-session
  // count and oldest/newest timestamps with the span in days (SK-18). Records
  // without a parseable `ts` contribute to the session count but not the span.
  const sessions = new Set();
  for (const rec of records) {
    if (rec.session) {
      sessions.add(rec.session);
    }
  }
  const timestamps = [];
  for (const rec of records) {
    const ts = rec.ts;
    if (!ts) {
      continue;
    }
    const when = _parseIso(ts);
    if (when === null) {
      continue;
    }
    timestamps.push({ ms: when, raw: ts });
  }
  let oldest = null;
  let newest = null;
  for (const t of timestamps) {
    if (oldest === null || t.ms < oldest.ms) {
      oldest = t;
    }
    if (newest === null || t.ms > newest.ms) {
      newest = t;
    }
  }
  const spanDays =
    oldest !== null
      ? _round2((newest.ms - oldest.ms) / 1000 / 86400)
      : null;
  return {
    distinct_sessions: sessions.size,
    oldest_ts: oldest !== null ? _isoFromRaw(oldest.raw) : null,
    newest_ts: newest !== null ? _isoFromRaw(newest.raw) : null,
    span_days: spanDays,
  };
}

function _isoFromRaw(raw) {
  // The Python code stored a parsed datetime and re-emitted .isoformat(); for
  // the offsets the log carries, fromisoformat -> isoformat round-trips to the
  // same string, so returning the original text is equivalent and avoids
  // reformatting drift.
  return raw;
}

function _round2(x) {
  // Python round() uses banker's rounding, but the values here (span in days
  // from second-granular timestamps) don't land on .xx5 ties in practice; a
  // 2-decimal round matches. Strip a trailing ".0" the way Python's round
  // returns a float that json renders as e.g. 0.01 (not "0.010").
  return Math.round(x * 100) / 100;
}

function _newDefaultAllowGroup() {
  return { count: 0, samples: [], cwds: new Set(), pattern: null, auto: 0 };
}
function _newDefaultAskGroup() {
  return { count: 0, samples: [], reasons: new Set() };
}
function _newDefaultDenyGroup() {
  return { count: 0, samples: [] };
}

function analyze(records, allowPrefixes, minCount, maxSamples) {
  const allowGroups = new Map();
  const askGroups = new Map();
  const denyGroups = new Map();
  const byMode = new Map();

  for (const rec of records) {
    const mode = rec.mode || "unspecified";
    byMode.set(mode, (byMode.get(mode) || 0) + 1);
    const decision = rec.decision;
    // Current records log the shape directly ([LOG-03]); legacy records carry a
    // raw `command`. Reduce either to a shape, so the analyzer never surfaces a
    // raw command — even out of an old log.
    const src = rec.command_shape || rec.command;
    if (!src) {
      continue; // file-content (Write/Edit) records have no command to group
    }
    const [shape, pattern] = commandShape(src);

    if (decision === "allow") {
      // Suppress on the shape, not the raw src: grouping keys on the shape
      // (which drops leading VAR=value/sudo), so the already-allowed check must
      // too.
      if (isAlreadyAllowed(shape, allowPrefixes)) {
        continue;
      }
      let g = allowGroups.get(shape);
      if (!g) {
        g = _newDefaultAllowGroup();
        allowGroups.set(shape, g);
      }
      g.count += 1;
      g.pattern = pattern;
      if (rec.mode === "auto") {
        g.auto += 1;
      }
      if (rec.cwd) {
        g.cwds.add(rec.cwd);
      }
      if (g.samples.length < maxSamples && !g.samples.includes(shape)) {
        g.samples.push(shape);
      }
    } else if (decision === "ask") {
      let g = askGroups.get(shape);
      if (!g) {
        g = _newDefaultAskGroup();
        askGroups.set(shape, g);
      }
      g.count += 1;
      for (const reason of rec.matched || []) {
        g.reasons.add(reason);
      }
      if (g.samples.length < maxSamples && !g.samples.includes(shape)) {
        g.samples.push(shape);
      }
    } else if (decision === "deny") {
      const matched =
        rec.matched && rec.matched.length ? rec.matched : ["(unattributed)"];
      for (const reason of matched) {
        let g = denyGroups.get(reason);
        if (!g) {
          g = _newDefaultDenyGroup();
          denyGroups.set(reason, g);
        }
        g.count += 1;
        if (g.samples.length < maxSamples && !g.samples.includes(shape)) {
          g.samples.push(shape);
        }
      }
    }
  }

  const allowCandidates = [];
  for (const [shape, g] of allowGroups) {
    if (g.count >= minCount) {
      allowCandidates.push({
        shape,
        suggested_allow: g.pattern,
        count: g.count,
        auto_executed: g.auto,
        distinct_dirs: g.cwds.size,
        samples: g.samples,
      });
    }
  }
  const exceptCandidates = [];
  for (const [shape, g] of askGroups) {
    if (g.count >= minCount) {
      exceptCandidates.push({
        shape,
        count: g.count,
        reasons: [...g.reasons].sort(),
        samples: g.samples,
      });
    }
  }
  const denySummary = [];
  for (const [reason, g] of denyGroups) {
    denySummary.push({ reason, count: g.count, samples: g.samples });
  }

  // Match Python's sort(key=lambda x: (-count, key)) — stable sort by descending
  // count then ascending shape/reason.
  allowCandidates.sort(
    (a, b) => b.count - a.count || _cmp(a.shape, b.shape),
  );
  exceptCandidates.sort(
    (a, b) => b.count - a.count || _cmp(a.shape, b.shape),
  );
  denySummary.sort((a, b) => b.count - a.count || _cmp(a.reason, b.reason));

  const byModeObj = {};
  for (const [k, v] of byMode) {
    byModeObj[k] = v;
  }

  return {
    allow_candidates: allowCandidates,
    except_candidates: exceptCandidates,
    deny_summary: denySummary,
    by_mode: byModeObj,
  };
}

function _cmp(a, b) {
  // String comparison matching Python's < on str (codepoint order).
  if (a < b) return -1;
  if (a > b) return 1;
  return 0;
}

function _parseArgs(argv) {
  // Minimal argparse-equivalent for the analyzer's flags. Defaults match the
  // documented behavior (--min-count 3, --max-samples 5).
  const args = {
    log: process.env.CLAUDEWATCH_LOG !== undefined ? process.env.CLAUDEWATCH_LOG : null,
    settings: DEFAULT_SETTINGS,
    since: null,
    min_count: 3,
    max_samples: 5,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const takeVal = (name) => {
      // Support both `--flag value` and `--flag=value`.
      const eq = a.indexOf("=");
      if (eq !== -1) {
        return a.slice(eq + 1);
      }
      i += 1;
      if (i >= argv.length) {
        _argError(`argument ${name}: expected one argument`);
      }
      return argv[i];
    };
    if (a === "--log" || a.startsWith("--log=")) {
      args.log = takeVal("--log");
    } else if (a === "--settings" || a.startsWith("--settings=")) {
      args.settings = takeVal("--settings");
    } else if (a === "--since" || a.startsWith("--since=")) {
      args.since = takeVal("--since");
    } else if (a === "--min-count" || a.startsWith("--min-count=")) {
      args.min_count = parseInt(takeVal("--min-count"), 10);
    } else if (a === "--max-samples" || a.startsWith("--max-samples=")) {
      args.max_samples = parseInt(takeVal("--max-samples"), 10);
    } else if (a === "-h" || a === "--help") {
      process.stdout.write(
        "usage: analyze.mjs [--log PATH] [--settings PATH] [--since DUR] " +
          "[--min-count N] [--max-samples N]\n",
      );
      process.exit(0);
    } else {
      _argError(`unrecognized arguments: ${a}`);
    }
  }
  return args;
}

function _argError(msg) {
  process.stderr.write(`analyze: ${msg}\n`);
  process.exit(2);
}

function main() {
  const args = _parseArgs(process.argv.slice(2));

  // Resolve the log path the same way the engine does (watchdog.mjs _logEvent):
  // unset or an "on" token -> default path; an "off" token -> still look at the
  // default path so the not-found guidance can explain that logging is disabled.
  let loggingDisabled = false;
  if (args.log === null) {
    args.log = DEFAULT_LOG;
  } else {
    const token = args.log.trim().toLowerCase();
    if (["", "off", "0", "false", "none"].includes(token)) {
      loggingDisabled = true;
      args.log = DEFAULT_LOG;
    } else if (["1", "true", "on", "yes"].includes(token)) {
      args.log = DEFAULT_LOG;
    }
  }

  let cutoffMs = null;
  if (args.since) {
    let delta;
    try {
      delta = parseDuration(args.since);
    } catch (e) {
      if (e instanceof DurationError) {
        process.stderr.write(`analyze: ${e.message}\n`);
        process.exit(2);
      }
      throw e;
    }
    cutoffMs = Date.now() - delta;
  }

  let records;
  try {
    records = readRecords(args.log, cutoffMs);
  } catch (e) {
    if (e instanceof NotFoundError) {
      if (loggingDisabled) {
        process.stderr.write(
          "analyze: logging is disabled (CLAUDEWATCH_LOG is set to off).\n" +
            "Decision logging is on by default; remove the off setting from the hook\n" +
            "environment in settings.json to re-enable it, then run some sessions.\n",
        );
      } else {
        process.stderr.write(
          `analyze: no decision log at ${_expanduser(args.log)} yet.\n` +
            "Logging is on by default; this usually means no sessions have run with the\n" +
            "ClaudeWatch hook active. Run some sessions, then review.\n",
        );
      }
      process.exit(2);
    }
    throw e;
  }

  const allowPrefixes = loadAllowPrefixes(args.settings);
  const result = analyze(records, allowPrefixes, args.min_count, args.max_samples);
  result.meta = {
    log: _expanduser(args.log),
    records_considered: records.length,
    since: args.since,
    min_count: args.min_count,
    ...summarizeWindow(records),
  };
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
}

main();
