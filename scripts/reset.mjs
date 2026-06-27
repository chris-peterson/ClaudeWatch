#!/usr/bin/env node
/*
 * reset: clear the ClaudeWatch decision log so the next analysis measures from
 * a fresh baseline.
 *
 * Node standard library only (node: built-ins); no npm deps. ESM.
 *
 * After `/ClaudeWatch:learn` proposals are applied (allow-list additions, rule
 * edits) the accumulated history would otherwise keep re-surfacing the same
 * already-dispositioned commands. Resetting starts the next window from the
 * post-change baseline (SK-19).
 *
 * By default the log is **archived** — moved to `~/.claude/claudewatch/archive/`
 * beside the durable log — so prior history stays recoverable, matching the
 * project's "block is for no-recovery" ethos. `--hard` deletes it outright.
 *
 * Resolves the log path the same way the engine does (watchdog.mjs _logEvent):
 *   - unset, "1"/"true"/"on"/"yes"  -> default path
 *   - "off"/"0"/"false"/"none"/""   -> logging disabled (nothing to reset)
 *   - anything else                 -> treated as the destination path
 *
 * Stdlib-only, no network.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import process from "node:process";

const DEFAULT_LOG = "~/.claude/claudewatch/decisions.jsonl";
const _LOG_OFF_VALUES = new Set(["", "off", "0", "false", "none"]);
const _LOG_DEFAULT_VALUES = new Set(["1", "true", "on", "yes"]);

function _expanduser(p) {
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

function resolveLog(argLog) {
  // Return [path, disabled] mirroring the engine's CLAUDEWATCH_LOG handling.
  const raw =
    argLog !== null
      ? argLog
      : process.env.CLAUDEWATCH_LOG !== undefined
        ? process.env.CLAUDEWATCH_LOG
        : null;
  if (raw === null) {
    return [_expanduser(DEFAULT_LOG), false];
  }
  const token = raw.trim().toLowerCase();
  if (_LOG_OFF_VALUES.has(token)) {
    return [_expanduser(DEFAULT_LOG), true];
  }
  if (_LOG_DEFAULT_VALUES.has(token)) {
    return [_expanduser(DEFAULT_LOG), false];
  }
  return [_expanduser(raw), false];
}

function _parseIso(ts) {
  const d = new Date(ts);
  const t = d.getTime();
  return Number.isNaN(t) ? null : t;
}

function summarize(p) {
  // Count records and the oldest/newest timestamps in the log.
  let count = 0;
  const timestamps = [];
  const content = fs.readFileSync(p, "utf8");
  for (let line of content.split("\n")) {
    line = line.trim();
    if (!line) {
      continue;
    }
    if (line.startsWith('{"schema":')) {
      continue; // the log's schema header ([LOG-06]), not a decision record
    }
    count += 1;
    // Cheap ts pull without a full JSON parse per line; the field is always
    // first in the record (the engine writes it first).
    const marker = '"ts":"';
    let i = line.indexOf(marker);
    if (i === -1) {
      continue;
    }
    i += marker.length;
    const j = line.indexOf('"', i);
    if (j === -1) {
      continue;
    }
    const when = _parseIso(line.slice(i, j));
    if (when === null) {
      continue;
    }
    timestamps.push({ ms: when, raw: line.slice(i, j) });
  }
  let oldest = null;
  let newest = null;
  for (const t of timestamps) {
    if (oldest === null || t.ms < oldest.ms) oldest = t;
    if (newest === null || t.ms > newest.ms) newest = t;
  }
  const spanDays =
    oldest !== null
      ? Math.round(((newest.ms - oldest.ms) / 1000 / 86400) * 100) / 100
      : null;
  return { count, oldest, newest, spanDays };
}

function _utcStamp(d) {
  // Match Python datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"):
  // YYYYMMDDTHHMMSS + 6-digit microseconds + Z. JS Date has ms resolution, so
  // pad the micros with three trailing zeros.
  const iso = d.toISOString(); // 2026-06-27T12:34:56.789Z
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{3})Z$/.exec(iso);
  if (!m) {
    // Defensive: toISOString always matches the pattern.
    return iso.replace(/[-:.]/g, "");
  }
  const [, Y, Mo, D, H, Mi, S, ms] = m;
  return `${Y}${Mo}${D}T${H}${Mi}${S}${ms}000Z`;
}

function _parseArgs(argv) {
  const args = { log: null, hard: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--log" || a.startsWith("--log=")) {
      const eq = a.indexOf("=");
      if (eq !== -1) {
        args.log = a.slice(eq + 1);
      } else {
        i += 1;
        if (i >= argv.length) {
          process.stderr.write("reset: argument --log: expected one argument\n");
          process.exit(2);
        }
        args.log = argv[i];
      }
    } else if (a === "--hard") {
      args.hard = true;
    } else if (a === "-h" || a === "--help") {
      process.stdout.write("usage: reset.mjs [--log PATH] [--hard]\n");
      process.exit(0);
    } else {
      process.stderr.write(`reset: unrecognized arguments: ${a}\n`);
      process.exit(2);
    }
  }
  return args;
}

function _isFile(p) {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

function main() {
  const args = _parseArgs(process.argv.slice(2));
  const [logPath, disabled] = resolveLog(args.log);

  if (disabled) {
    process.stderr.write(
      "reset: logging is disabled (CLAUDEWATCH_LOG is set to off); " +
        "there is no active log to reset.\n",
    );
    process.exit(2);
  }

  if (!_isFile(logPath)) {
    process.stdout.write(
      `reset: no decision log at ${logPath}; nothing to reset.\n`,
    );
    process.exit(0);
  }

  const { count, oldest, newest, spanDays } = summarize(logPath);
  const span =
    oldest !== null
      ? `${count} records across ${spanDays} days (${oldest.raw} → ${newest.raw})`
      : `${count} records`;

  if (args.hard) {
    fs.rmSync(logPath);
    process.stdout.write(`reset: deleted decision log (${span}).\n`);
    process.exit(0);
  }

  const archiveDir = path.join(path.dirname(logPath), "archive");
  fs.mkdirSync(archiveDir, { recursive: true });
  const stamp = _utcStamp(new Date());
  const dest = path.join(archiveDir, `decisions-${stamp}.jsonl`);
  fs.renameSync(logPath, dest);
  process.stdout.write(`reset: archived decision log (${span}) to ${dest}.\n`);
  process.exit(0);
}

main();
