#!/usr/bin/env node
/*
 * claude-watchdog: PreToolUse hook for Claude Code
 *
 * Generic rule engine that enforces safety rules loaded from YAML config files.
 * Reads tool input JSON from stdin, evaluates all rule sets in a directory,
 * and outputs a single coalesced JSON decision to stdout.
 *
 * Node port of scripts/watchdog.py — behaviorally identical. Node ships with
 * Claude Code, so this runs natively on every platform without resolving a
 * Python interpreter. Standard library only (node: built-ins); no npm deps.
 *
 * Supports three tool inputs:
 * - Bash: matches against tool_input.command (target: bash rules)
 * - Write: matches against tool_input.content (target: file-content rules)
 * - Edit: matches against the full post-edit file content reconstructed from
 *   the on-disk file plus tool_input.old_string -> tool_input.new_string
 *   substitution (target: file-content rules)
 *
 * Each decision is appended as a JSONL record to ~/.claude/claudewatch/decisions.jsonl
 * by default — the side channel the /ClaudeWatch:learn workflow reads. Set
 * CLAUDEWATCH_LOG to a path to log elsewhere, or to "off" (also 0/false/none/empty)
 * to disable it. Logging never affects the decision itself.
 *
 * The ask-prompt reason reads `<rule>: <reason>`, where the reason prose is a
 * clickable OSC 8 terminal hyperlink to the rule's `ref` — so the verbose URL
 * stays out of the line. Set CLAUDEWATCH_HYPERLINKS to "off" (also
 * 0/false/none/empty) to keep the plain `— <url>` form instead. Deny messages
 * always use the plain `— <url>` form: Claude Code renders them through its error
 * path, which strips OSC 8 without linking it. Deny messages also append the
 * `[plugin:ClaudeWatch]` source tag that Claude Code shows on ask prompts but
 * omits on deny errors. The logged reasons stay plain text regardless — no tag.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import process from "node:process";
import { fileURLToPath } from "node:url";

const VALID_TARGETS = ["bash", "file-content"];

// ---------------------------------------------------------------------------
// Regex translation (Python `re` -> JS `RegExp`)
//
// Every rule pattern, the top-level filter, and a rule's except are Python `re`
// patterns used with re.search (find anywhere, UNANCHORED). Build a RegExp and
// .test() it — test is unanchored, matching re.search.
//
// Python patterns may start with a leading inline-flag token like `(?i)`,
// `(?is)`, etc. JS has no bare flag-setter, so detect a leading `(?<flags>)`
// token, map the letters to JS flags, and strip the token from the source.
// ---------------------------------------------------------------------------

const _LEADING_INLINE_FLAGS = /^\(\?([imsx]+)\)/;

function _compileRegex(pattern) {
  // Lift a leading inline-flag token (e.g. `(?i)`) into JS RegExp flags.
  // Mid-pattern inline flags do NOT translate to a simple flag lift; none
  // exist in the shipped rules (audited), and the RegExp constructor throws
  // on an unsupported `(?i)` mid-pattern, which surfaces as an invalid-regex
  // block — never a silent mistranslation.
  let source = pattern;
  let flags = "";
  const m = _LEADING_INLINE_FLAGS.exec(source);
  if (m) {
    const letters = m[1];
    // Python `x` (verbose) has no JS equivalent; it is absent from the shipped
    // rules. Map the flags JS supports; an unmapped letter would be ignored,
    // but none appear in practice.
    if (letters.includes("i")) flags += "i";
    if (letters.includes("m")) flags += "m";
    if (letters.includes("s")) flags += "s";
    source = source.slice(m[0].length);
  }
  // No `u` flag by default: Python \d\w\b are Unicode, JS defaults to ASCII;
  // for these ASCII command patterns they match identically.
  return new RegExp(source, flags);
}

// re.search(pat, text) -> build RegExp and .test(text) (unanchored).
function _reSearch(pattern, text) {
  return _compileRegex(pattern).test(text);
}

// ---------------------------------------------------------------------------
// YAML parsing
// ---------------------------------------------------------------------------

function _unquote(s) {
  if (s.length >= 2 && s[0] === "'" && s[s.length - 1] === "'") {
    return s.slice(1, -1).replaceAll("''", "'");
  }
  if (s.length >= 2 && s[0] === '"' && s[s.length - 1] === '"') {
    return s.slice(1, -1);
  }
  return s;
}

function _parseInlineList(val) {
  // Parse YAML inline list syntax like ['.ps1', '.psm1'] or [.ps1, .psm1].
  val = val.trim();
  if (!(val.startsWith("[") && val.endsWith("]"))) {
    return [];
  }
  const inner = val.slice(1, -1).trim();
  if (!inner) {
    return [];
  }
  return inner
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item)
    .map((item) => _unquote(item));
}

function _lstripLen(line) {
  // Number of leading whitespace characters (matches Python len(line) - len(line.lstrip())).
  let i = 0;
  while (i < line.length && /\s/.test(line[i])) {
    i += 1;
  }
  return i;
}

function _pyRepr(s) {
  // Approximate Python's repr() for a string, used in stderr warnings so the
  // surfaced text matches watchdog.py. Python prefers single quotes unless the
  // string contains a single quote (and no double quote), in which case it uses
  // double quotes.
  const hasSingle = s.includes("'");
  const hasDouble = s.includes('"');
  let quote = "'";
  if (hasSingle && !hasDouble) {
    quote = '"';
  }
  let body = s.replaceAll("\\", "\\\\");
  if (quote === "'") {
    body = body.replaceAll("'", "\\'");
  } else {
    body = body.replaceAll('"', '\\"');
  }
  return quote + body + quote;
}

function parseRulesYml(filePath) {
  const result = {
    name: "",
    filter: "",
    extensions: [],
    rules: { block: [], ask: [] },
  };
  let currentSection = null;
  let currentItem = null;

  const raw = fs.readFileSync(filePath, "utf8");
  // Python iterates lines including the trailing newline, then rstrip("\n").
  // Splitting on "\n" gives the same per-line content (a trailing newline just
  // yields a final empty string, which is skipped as blank).
  const lines = raw.split("\n");

  for (const rawLine of lines) {
    const line = rawLine.replace(/\n$/, "");
    const stripped = line.trim();

    if (!stripped || stripped.startsWith("#")) {
      continue;
    }

    const indent = _lstripLen(line);

    if (indent === 0 && stripped.startsWith("name:")) {
      result.name = _unquote(stripped.slice(5).trim());
    } else if (indent === 0 && stripped.startsWith("filter:")) {
      result.filter = _unquote(stripped.slice(7).trim());
    } else if (indent === 0 && stripped.startsWith("extensions:")) {
      result.extensions = _parseInlineList(stripped.slice(11).trim());
    } else if (indent === 0 && stripped === "rules:") {
      // no-op
    } else if (indent === 2 && (stripped === "block:" || stripped === "ask:")) {
      currentSection = stripped.slice(0, -1);
      currentItem = null;
    } else if (
      indent === 4 &&
      stripped.startsWith("- name:") &&
      currentSection !== null
    ) {
      currentItem = {
        name: _unquote(stripped.slice(7).trim()),
        pattern: "",
        reason: "",
        ref: "",
        target: "bash",
      };
      result.rules[currentSection].push(currentItem);
    } else if (
      indent === 4 &&
      stripped.startsWith("- pattern:") &&
      currentSection !== null
    ) {
      currentItem = {
        name: "",
        pattern: _unquote(stripped.slice(10).trim()),
        reason: "",
        ref: "",
        target: "bash",
      };
      result.rules[currentSection].push(currentItem);
    } else if (
      indent === 6 &&
      stripped.startsWith("pattern:") &&
      currentItem !== null
    ) {
      currentItem.pattern = _unquote(stripped.slice(8).trim());
    } else if (
      indent === 6 &&
      stripped.startsWith("name:") &&
      currentItem !== null
    ) {
      currentItem.name = _unquote(stripped.slice(5).trim());
    } else if (
      indent === 6 &&
      stripped.startsWith("reason:") &&
      currentItem !== null
    ) {
      currentItem.reason = _unquote(stripped.slice(7).trim());
    } else if (
      indent === 6 &&
      stripped.startsWith("ref:") &&
      currentItem !== null
    ) {
      currentItem.ref = _unquote(stripped.slice(4).trim());
    } else if (
      indent === 6 &&
      stripped.startsWith("target:") &&
      currentItem !== null
    ) {
      currentItem.target = _unquote(stripped.slice(7).trim());
    } else if (
      indent === 6 &&
      stripped.startsWith("except:") &&
      currentItem !== null
    ) {
      if (currentSection === "block") {
        const ruleName = currentItem.name !== undefined ? currentItem.name : "?";
        process.stderr.write(
          `warning: ${result.name || filePath} — rule ${_pyRepr(ruleName)} has 'except' on a block rule (ignored — except only applies to ask rules)\n`,
        );
      } else {
        currentItem.except = _unquote(stripped.slice(7).trim());
      }
    } else {
      // Unrecognized line — warn so typos surface instead of silently disappearing.
      const label = result.name || filePath;
      let where = "";
      if (indent === 0) {
        where = "top-level";
      } else if (indent === 2) {
        where = "section header";
      } else if (indent === 4) {
        where = "list item";
      } else if (indent === 6) {
        const ruleName = currentItem
          ? currentItem.name !== undefined
            ? currentItem.name
            : "?"
          : "?";
        where = `rule ${_pyRepr(ruleName)}`;
      } else {
        where = `indent ${indent}`;
      }
      process.stderr.write(
        `warning: ${label} — unrecognized line in ${where}: ${_pyRepr(stripped)}\n`,
      );
    }
  }

  return result;
}

// ---------------------------------------------------------------------------
// Violations and message formatting
// ---------------------------------------------------------------------------

function _violation(rule) {
  return {
    prefix: rule.name || "",
    reason: rule.reason,
    ref: rule.ref || "",
  };
}

function _errorViolation(text) {
  return { prefix: "", reason: text, ref: "" };
}

function _messagePlain(v) {
  const head = v.prefix ? `${v.prefix}: ${v.reason}` : v.reason;
  return v.ref ? `${head} — ${v.ref}` : head;
}

const _OSC8 = "\x1b]8;;";
const _ST = "\x1b\\";

const _PLUGIN_TAG = "[plugin:ClaudeWatch]";

function _hyperlink(url, text) {
  return `${_OSC8}${url}${_ST}${text}${_OSC8}${_ST}`;
}

const _HYPERLINKS_OFF_VALUES = new Set(["off", "0", "false", "none", ""]);

function _hyperlinksEnabled() {
  const raw = process.env.CLAUDEWATCH_HYPERLINKS;
  if (raw === undefined) {
    return true;
  }
  return !_HYPERLINKS_OFF_VALUES.has(raw.trim().toLowerCase());
}

function _messageDisplay(v, hyperlinks) {
  if (hyperlinks && v.ref) {
    const linked = _hyperlink(v.ref, v.reason);
    return v.prefix ? `${v.prefix}: ${linked}` : linked;
  }
  return _messagePlain(v);
}

function _ruleTarget(rule) {
  return rule.target || "bash";
}

// ---------------------------------------------------------------------------
// Compound-command detection
// ---------------------------------------------------------------------------

// Quoted spans carry string data, not shell syntax, so they are stripped before
// scanning for control operators.
const _QUOTED_SPAN = /'[^']*'|"[^"]*"/g;
// Shell control operators that chain multiple commands.
const _SHELL_COMPOUND = /\||;|\n|&&|\$\(|`/;

function _isCompoundCommand(command) {
  return _SHELL_COMPOUND.test(command.replace(_QUOTED_SPAN, ""));
}

function _compoundEscalation() {
  return {
    prefix: "compound command",
    reason:
      "escalated to block — a piped or chained command can be auto-approved segment-by-segment by the host allow list, which skips this confirmation; run the guarded command on its own to be prompted",
    ref: "",
  };
}

// ---------------------------------------------------------------------------
// Rule evaluation
// ---------------------------------------------------------------------------

function evaluateRules(config, inputKind, inputText, fileExtension) {
  const blocks = [];
  const asks = [];
  const label = config.name || "unknown";

  const _block = (reason) => {
    blocks.push(_errorViolation(reason));
  };

  if (inputKind === "bash") {
    const filt = config.filter;
    if (filt) {
      try {
        if (!_reSearch(filt, inputText)) {
          return [blocks, asks];
        }
      } catch (e) {
        _block(`${label} — invalid filter regex: ${_reErrorMessage(e, filt)}`);
        return [blocks, asks];
      }
    }
  } else {
    // file-content
    const extensions = config.extensions || [];
    if (extensions.length === 0) {
      return [blocks, asks];
    }
    const lowered = extensions.map((e) => e.toLowerCase());
    if (
      fileExtension === null ||
      fileExtension === undefined ||
      !lowered.includes(fileExtension.toLowerCase())
    ) {
      return [blocks, asks];
    }
  }

  const rules = config.rules || {};

  for (const rule of rules.block || []) {
    const target = _ruleTarget(rule);
    if (!VALID_TARGETS.includes(target)) {
      _block(`${label} — rule ${_pyRepr(_ruleNameOrQ(rule))} has invalid target ${_pyRepr(target)}`);
      continue;
    }
    if (target !== inputKind) {
      continue;
    }
    if (!rule.pattern) {
      _block(`${label} — rule ${_pyRepr(_ruleNameOrQ(rule))} has empty pattern`);
      continue;
    }
    try {
      if (_reSearch(rule.pattern, inputText)) {
        blocks.push(_violation(rule));
      }
    } catch (e) {
      _block(`${label} — rule ${_pyRepr(_ruleNameOrQ(rule))} has invalid regex: ${_reErrorMessage(e, rule.pattern)}`);
    }
  }

  for (const rule of rules.ask || []) {
    const target = _ruleTarget(rule);
    if (!VALID_TARGETS.includes(target)) {
      _block(`${label} — rule ${_pyRepr(_ruleNameOrQ(rule))} has invalid target ${_pyRepr(target)}`);
      continue;
    }
    if (target !== inputKind) {
      continue;
    }
    if (!rule.pattern) {
      _block(`${label} — rule ${_pyRepr(_ruleNameOrQ(rule))} has empty pattern`);
      continue;
    }
    try {
      if (_reSearch(rule.pattern, inputText)) {
        const exc = rule.except;
        if (exc) {
          try {
            if (_reSearch(exc, inputText)) {
              continue;
            }
          } catch (e) {
            _block(`${label} — rule ${_pyRepr(_ruleNameOrQ(rule))} has invalid 'except' regex: ${_reErrorMessage(e, exc)}`);
            continue;
          }
        }
        asks.push(_violation(rule));
      }
    } catch (e) {
      _block(`${label} — rule ${_pyRepr(_ruleNameOrQ(rule))} has invalid regex: ${_reErrorMessage(e, rule.pattern)}`);
    }
  }

  return [blocks, asks];
}

function _ruleNameOrQ(rule) {
  // Python uses rule.get('name', '?') — returns '?' only when the key is absent.
  // Parsed rules always carry a name key (possibly ""), matching Python's dicts.
  return "name" in rule ? rule.name : "?";
}

function _reErrorMessage(e, _pattern) {
  // The tests assert only the decision (block) for invalid-regex cases, not the
  // exact error text, so the message body is free-form. Surface the engine's
  // own error message.
  return e && e.message ? e.message : String(e);
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

const DEFAULT_LOG_PATH = "~/.claude/claudewatch/decisions.jsonl";
const _LOG_OFF_VALUES = new Set(["", "off", "0", "false", "none"]);
const _LOG_DEFAULT_VALUES = new Set(["1", "true", "on", "yes"]);
const LOG_SCHEMA_VERSION = 2;

function _expanduser(p) {
  // Match Python os.path.expanduser: expand a leading ~ to the user's home,
  // taken from $HOME (or USERPROFILE on Windows) so the tests' HOME override
  // resolves the default log path under the sandbox.
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
  // ~user form is not expanded by Python when the user can't be resolved; for
  // ClaudeWatch's fixed default path this branch is unreachable.
  return p;
}

function _logSchemaOf(dest) {
  // Read only the first line (Python uses f.readline()): the decision log is
  // never rotated and grows unbounded, so reading it whole on every hot-path
  // write would be O(log size). Pull bytes through a bounded buffer until the
  // first newline.
  let first;
  let fd;
  try {
    fd = fs.openSync(dest, "r");
  } catch {
    return null;
  }
  try {
    const CHUNK = 4096;
    const buf = Buffer.alloc(CHUNK);
    let acc = "";
    for (;;) {
      const n = fs.readSync(fd, buf, 0, CHUNK, null);
      if (n === 0) {
        first = acc;
        break;
      }
      acc += buf.toString("utf8", 0, n);
      const nl = acc.indexOf("\n");
      if (nl !== -1) {
        first = acc.slice(0, nl + 1);
        break;
      }
    }
  } catch {
    return null;
  } finally {
    fs.closeSync(fd);
  }
  try {
    const parsed = JSON.parse(first);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      return "schema" in parsed ? parsed.schema : undefined;
    }
    // A non-object first line (e.g. a JSON number/array) has no .get -> Python
    // raises AttributeError, caught and returns None.
    return null;
  } catch {
    return null;
  }
}

const SUBCOMMAND_TOOLS = new Set([
  "git", "gh", "glab", "npm", "npx", "yarn", "pnpm", "pip", "pip3", "cargo",
  "go", "docker", "kubectl", "just", "make", "brew", "terraform", "bundle",
  "rake", "dotnet", "aws", "gcloud", "az", "systemctl", "apt", "apt-get",
  "uv", "poetry", "deno", "bun",
]);

const _VAR_ASSIGN = /^(?:[A-Za-z_][A-Za-z0-9_]*=[\s\S]*)$/;
const _SUBCOMMAND_LIKE = /^[a-z][a-z0-9-]*$/;
const _MAX_SHAPE_TOKENS = 4;

function _posixBasename(p) {
  // Match Python os.path.basename: everything after the last '/', with no
  // trailing-slash stripping — os.path.basename('bar/') is '' (Node's
  // path.basename('bar/') is 'bar'). The shape this produces is the contract
  // analyze.py re-derives, so it must match Python exactly. ClaudeWatch's rules
  // and shapes are POSIX-style, so split on '/' regardless of host separator.
  const idx = p.lastIndexOf("/");
  return idx === -1 ? p : p.slice(idx + 1);
}

function _splitWhitespace(s) {
  // Match Python str.split() with no args: split on runs of whitespace, drop
  // empties. (s.strip().split() in Python.)
  const t = s.trim();
  if (!t) {
    return [];
  }
  return t.split(/\s+/);
}

function commandShape(command) {
  const tokens = _splitWhitespace(command);
  let i = 0;
  while (
    i < tokens.length &&
    (_VAR_ASSIGN.test(tokens[i]) || tokens[i] === "sudo")
  ) {
    i += 1;
  }
  if (i >= tokens.length) {
    const c = command.trim();
    return [c, `Bash(${c})`];
  }

  const prog = _posixBasename(tokens[i]);
  const shapeTokens = [prog];
  if (SUBCOMMAND_TOOLS.has(prog)) {
    let j = i + 1;
    while (
      j < tokens.length &&
      shapeTokens.length < _MAX_SHAPE_TOKENS &&
      _SUBCOMMAND_LIKE.test(tokens[j])
    ) {
      shapeTokens.push(tokens[j]);
      j += 1;
    }
  }

  const shape = shapeTokens.join(" ");
  return [shape, `Bash(${shape}:*)`];
}

function _compactJson(obj) {
  // JSON.stringify is compact by default — matches Python separators=(",",":").
  return JSON.stringify(obj);
}

function _isoformatUtc(d) {
  // Match Python datetime.now(timezone.utc).isoformat(): a `+00:00` suffix, and
  // a 6-digit fractional second that is OMITTED entirely when sub-second is
  // exactly 0. JS Date has only millisecond resolution, so pad the microsecond
  // digits with three trailing zeros.
  const base = d.toISOString(); // e.g. 2026-06-27T12:34:56.789Z
  const noZ = base.slice(0, -1); // drop trailing Z
  const dot = noZ.indexOf(".");
  if (dot === -1) {
    // No fractional component (Date.toISOString always emits .mmm, so this is a
    // defensive branch).
    return `${noZ}+00:00`;
  }
  const seconds = noZ.slice(0, dot);
  const millis = noZ.slice(dot + 1); // 3 digits
  if (millis === "000") {
    return `${seconds}+00:00`;
  }
  return `${seconds}.${millis}000+00:00`;
}

function _logEvent(data, inputKind, inputText, decision, matched) {
  const raw = process.env.CLAUDEWATCH_LOG;
  let dest;
  if (raw === undefined) {
    dest = DEFAULT_LOG_PATH;
  } else {
    const token = raw.trim().toLowerCase();
    if (_LOG_OFF_VALUES.has(token)) {
      return;
    }
    dest = _LOG_DEFAULT_VALUES.has(token) ? DEFAULT_LOG_PATH : raw;
  }
  dest = _expanduser(dest);

  const entry = {
    ts: _isoformatUtc(new Date()),
    session: _getOrNull(data, "session_id"),
    cwd: _getOrNull(data, "cwd"),
    tool: _getOrNull(data, "tool_name"),
    mode: _getOrNull(data, "permission_mode"),
    decision: decision,
    matched: matched,
  };
  if (inputKind === "bash") {
    entry.command_shape = commandShape(inputText)[0];
  } else {
    const toolInput = data.tool_input || {};
    entry.path = _getOrNull(toolInput, "file_path");
  }

  try {
    const parent = path.dirname(dest);
    if (parent) {
      fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
    }
    // Start a fresh, versioned log when none exists or the existing one is from
    // an older schema. A pre-shape log holds raw commands that may carry inline
    // secrets, so discard rather than carry it across an upgrade.
    let writeHeader = !fs.existsSync(dest);
    if (!writeHeader && _logSchemaOf(dest) !== LOG_SCHEMA_VERSION) {
      const hadContent = fs.statSync(dest).size > 0;
      fs.rmSync(dest);
      writeHeader = true;
      if (hadContent) {
        process.stderr.write(
          `watchdog: cleared a pre-schema-${LOG_SCHEMA_VERSION} decision log ` +
            `(it recorded raw commands); starting a fresh shape-only log at ${dest}\n`,
        );
      }
    }
    let out = "";
    if (writeHeader) {
      out += _compactJson({ schema: LOG_SCHEMA_VERSION }) + "\n";
    }
    out += _compactJson(entry) + "\n";
    fs.appendFileSync(dest, out);
    // Owner-only access. Applied every write so a pre-existing wider mode is
    // corrected. On Windows chmod honors only the read-only bit — same call on
    // every platform, no OS branching ([PL-04]).
    fs.chmodSync(dest, 0o600);
    if (parent) {
      fs.chmodSync(parent, 0o700);
    }
  } catch (e) {
    if (_isOSError(e)) {
      process.stderr.write(
        `watchdog: failed to write decision log to ${dest}: ${_osErrorText(e)}\n`,
      );
    } else {
      throw e;
    }
  }
}

function _getOrNull(obj, key) {
  // Match Python dict.get(key) -> None when absent, and the value otherwise.
  if (obj && Object.prototype.hasOwnProperty.call(obj, key)) {
    return obj[key];
  }
  return null;
}

function _isOSError(e) {
  // Node filesystem errors carry a string `code` (ENOENT, EACCES, ...). Treat
  // those as the OSError family Python catches; rethrow anything else.
  return e && typeof e.code === "string";
}

function _osErrorText(e) {
  return e && e.message ? e.message : String(e);
}

// ---------------------------------------------------------------------------
// Input resolution
// ---------------------------------------------------------------------------

function _splitext(p) {
  // Match Python os.path.splitext: returns the extension including the dot, or
  // "" when there is none. A leading dot in the basename is not an extension.
  const base = path.basename(p);
  // Strip leading dots (Python skips them when finding the extension).
  let i = 0;
  while (i < base.length && base[i] === ".") {
    i += 1;
  }
  const rest = base.slice(i);
  const dot = rest.lastIndexOf(".");
  if (dot <= 0) {
    return "";
  }
  return rest.slice(dot);
}

function _resolveInput(data) {
  const toolName = _getOrNull(data, "tool_name");
  const toolInput = data.tool_input || {};

  if (toolName === "Bash") {
    const cmd = toolInput.command || "";
    if (!cmd) {
      return null;
    }
    return ["bash", cmd, null];
  }

  if (toolName === "Write") {
    const content = toolInput.content || "";
    const p = toolInput.file_path || "";
    if (!content) {
      return null;
    }
    return ["file-content", content, _splitext(p)];
  }

  if (toolName === "Edit") {
    const p = toolInput.file_path || "";
    const oldString = toolInput.old_string || "";
    const newString = toolInput.new_string || "";
    const replaceAll = Boolean(toolInput.replace_all);
    if (!newString && !oldString) {
      return null;
    }
    let content;
    try {
      const existing = fs.readFileSync(p, "utf8");
      if (replaceAll) {
        content = _replaceAll(existing, oldString, newString);
      } else {
        content = _replaceFirst(existing, oldString, newString);
      }
    } catch {
      content = newString;
    }
    if (!content) {
      return null;
    }
    return ["file-content", content, _splitext(p)];
  }

  return null;
}

function _replaceFirst(haystack, needle, replacement) {
  // Match Python str.replace(old, new, 1). An empty needle in Python inserts the
  // replacement at the start (and would, for count=1, only at index 0).
  if (needle === "") {
    return replacement + haystack;
  }
  const idx = haystack.indexOf(needle);
  if (idx === -1) {
    return haystack;
  }
  return haystack.slice(0, idx) + replacement + haystack.slice(idx + needle.length);
}

function _replaceAll(haystack, needle, replacement) {
  // Match Python str.replace(old, new) with no count. An empty needle in Python
  // inserts the replacement at every position between characters and at both
  // ends — N+1 insertions for an N-char string. So '' -> 'X' (one position),
  // 'ab' -> 'XaXbX'. JS String.split('') yields one '' element for an empty
  // string (which would give 'XX'), so handle the empty haystack explicitly.
  if (needle === "") {
    if (haystack === "") {
      return replacement;
    }
    return replacement + haystack.split("").join(replacement) + replacement;
  }
  return haystack.split(needle).join(replacement);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function _emit(decision, reason) {
  process.stdout.write(
    _compactJson({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: decision,
        permissionDecisionReason: reason,
      },
    }) + "\n",
  );
}

function run(raw) {
  let data;
  try {
    data = JSON.parse(raw);
  } catch (e) {
    process.stderr.write(`watchdog: invalid JSON on stdin: ${e.message}\n`);
    return;
  }

  const resolved = _resolveInput(data);
  if (resolved === null) {
    return;
  }
  const [inputKind, inputText, fileExtension] = resolved;

  let target;
  if (process.argv.length > 2) {
    target = process.argv[2];
  } else {
    const here = path.dirname(fileURLToPath(import.meta.url));
    target = path.join(here, "..", "watches");
  }

  let ruleFiles;
  let stat = null;
  try {
    stat = fs.statSync(target);
  } catch {
    stat = null;
  }
  if (stat && stat.isDirectory()) {
    ruleFiles = fs
      .readdirSync(target)
      .filter((f) => f.endsWith(".yml"))
      .map((f) => path.join(target, f))
      .sort();
  } else if (stat && stat.isFile()) {
    ruleFiles = [target];
  } else {
    _emit("deny", `watchdog: rules not found: ${target}`);
    return;
  }

  const allBlocks = [];
  const allAsks = [];

  for (const ruleFile of ruleFiles) {
    let config;
    try {
      config = parseRulesYml(ruleFile);
    } catch (e) {
      allBlocks.push(
        _errorViolation(`watchdog: failed to load rules: ${e.message}`),
      );
      continue;
    }
    const [blocks, asks] = evaluateRules(
      config,
      inputKind,
      inputText,
      fileExtension,
    );
    allBlocks.push(...blocks);
    allAsks.push(...asks);
  }

  let decision;
  let chosen;
  if (allBlocks.length > 0) {
    decision = "deny";
    chosen = allBlocks;
  } else if (allAsks.length > 0) {
    decision = "ask";
    chosen = allAsks;
  } else {
    decision = "allow";
    chosen = [];
  }

  // A compound bash command can be auto-approved by the host segment-by-segment,
  // which pre-empts an ask. Escalate ask -> deny so the confirmation is not
  // skipped. Bare commands keep ask.
  if (decision === "ask" && inputKind === "bash" && _isCompoundCommand(inputText)) {
    decision = "deny";
    chosen = [_compoundEscalation(), ...chosen];
  }

  // Log the canonical plain text; render hyperlinks only in the prompt.
  _logEvent(
    data,
    inputKind,
    inputText,
    decision,
    chosen.map((v) => _messagePlain(v)),
  );

  if (decision !== "allow") {
    const hyperlinks = decision === "ask" && _hyperlinksEnabled();
    let reason = chosen.map((v) => _messageDisplay(v, hyperlinks)).join("\n");
    if (decision === "deny") {
      reason += ` ${_PLUGIN_TAG}`;
    }
    _emit(decision, reason);
  }
}

function main() {
  // Exit 0 in every path (core contract): a non-zero exit blocks the host from
  // getting a decision. Set exitCode rather than calling process.exit() so Node
  // flushes a fully-buffered stdout write before the process ends — process.exit()
  // can truncate a decision JSON larger than the OS pipe buffer (~64KB), which
  // would silently drop a deny.
  process.exitCode = 0;
  const chunks = [];
  process.stdin.on("data", (c) => chunks.push(c));
  process.stdin.on("end", () => {
    run(Buffer.concat(chunks).toString("utf8"));
  });
}

main();
