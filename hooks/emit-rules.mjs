#!/usr/bin/env node
/*
 * SessionStart hook: emit ClaudeWatch's ambient guidance into context. Stdout is
 * added to context on every SessionStart (startup, resume, compaction — no
 * matcher in hooks.json), so the guidance survives a compaction. It steers the
 * agent away from the compound-command escalation ([OUT-08]) before it triggers:
 * chaining a guarded command into a pipe turns an `ask` into a hard block, so a
 * session that learns to run guarded steps standalone hits fewer dead-end blocks.
 *
 * Node standard library only; ESM.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import process from "node:process";

const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT || "";
const rulesDir = path.join(pluginRoot, "rules");

let entries;
try {
  if (!fs.statSync(rulesDir).isDirectory()) {
    process.exit(0);
  }
  entries = fs.readdirSync(rulesDir);
} catch {
  process.exit(0);
}

process.stdout.write("# Ambient rules from the ClaudeWatch plugin\n\n");

// Match the shell glob `"$RULES_DIR"/*.md` order: shell expands a glob in
// sorted order, so sort the .md files the same way.
const mdFiles = entries.filter((f) => f.endsWith(".md")).sort();
for (const f of mdFiles) {
  process.stdout.write(fs.readFileSync(path.join(rulesDir, f), "utf8"));
  process.stdout.write("\n");
}
