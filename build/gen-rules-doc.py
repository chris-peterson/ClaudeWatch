#!/usr/bin/env python3
"""Generate docs/_site from rule sets and static docs (single source of truth)."""

import html
import os
import shutil
import sys

from importlib.util import spec_from_file_location, module_from_spec

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)


def load_parser():
    spec = spec_from_file_location("watchdog", os.path.join(ROOT_DIR, "scripts", "watchdog.py"))
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.parse_rules_yml


# FontAwesome 6 (loaded site-wide by the shared docsify bundle) + Dracula
# palette CSS variables from the shared theme — block reads as a hard "no",
# ask as an amber "halt for confirmation". No hardcoded colors.
ICON_BLOCK = '<i class="fa-solid fa-ban cw-status cw-block" title="Blocked outright — un-bypassable"></i>'
ICON_ASK = '<i class="fa-solid fa-hand cw-status cw-ask" title="Requires user confirmation"></i>'

STATUS_STYLE = "\n".join([
    "<style>",
    ".cw-status { width: 1.25em; text-align: center; font-size: 1.05em; }",
    ".cw-block { color: var(--color-red); }",
    ".cw-ask { color: var(--color-orange); }",
    "</style>",
])


def unified_table(config):
    rules = config["rules"]
    lines = ["| | Command | Reason | Ref |", "| --- | --- | --- | --- |"]
    for section, icon in [("block", ICON_BLOCK), ("ask", ICON_ASK)]:
        for r in rules[section]:
            raw_name = r.get("name", "").replace("|", "\\|")
            name = f"`{raw_name}`" if raw_name else ""
            reason = r["reason"].replace("|", "\\|")
            ref = f"[docs]({r['ref']})" if r["ref"] else ""
            lines.append(f"| {icon} | {name} | {reason} | {ref} |")
    lines.append("")
    lines.append(f"{ICON_BLOCK} blocked outright &nbsp;&nbsp; {ICON_ASK} requires user confirmation")
    return "\n".join(lines)


# Prompt-card styling, mimicking the Claude Code permission UI. Colors come
# from the shared theme variables (Dracula palette) so the cards adapt to
# light/dark mode — no hardcoded colors. Two shapes: an `ask` confirmation
# prompt (purple top rule, blue reason link, Yes/No options) and a `block`
# rejected-tool-result line (red bullet, red error with the plain `— <ref>`
# URL and the `[plugin:ClaudeWatch]` tag, matching the engine's deny output).
PROMPT_STYLE = "\n".join([
    "<style>",
    ".cw-prompt {",
    "  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;",
    "  font-size: 0.86em;",
    "  line-height: 1.55;",
    "  background: var(--code-theme-background);",
    "  border-radius: 6px;",
    "  padding: 0.85em 1.1em 1em;",
    "  margin: 1em 0 1.5em;",
    "  white-space: pre-wrap;",
    "  word-break: break-word;",
    "}",
    ".cw-prompt-ask   { border-top: 2px solid var(--color-purple); }",
    ".cw-prompt-block { border-top: 2px solid var(--color-red); }",
    ".cw-prompt-dim { color: var(--color-comment); }",
    ".cw-prompt code { background: none; padding: 0; color: inherit; }",
    ".cw-prompt-head { color: var(--color-purple); font-weight: 700; }",
    ".cw-prompt-cmd { padding-left: 2ch; margin-top: 0.7em; color: var(--color-foreground); }",
    ".cw-prompt-hook { margin-top: 0.9em; color: var(--color-foreground); }",
    ".cw-prompt-msg { color: var(--color-foreground); }",
    ".cw-prompt-msg a { color: var(--link-color); text-decoration: underline; }",
    ".cw-prompt-attr { color: var(--color-comment); }",
    ".cw-prompt-q { margin-top: 0.9em; color: var(--color-foreground); }",
    ".cw-prompt-opts { color: var(--color-comment); }",
    ".cw-prompt-cursor { color: var(--color-purple); font-weight: 700; }",
    ".cw-prompt-deny { color: var(--color-foreground); }",
    ".cw-prompt-bullet { color: var(--color-red); }",
    ".cw-prompt-denyerr { padding-left: 2ch; margin-top: 0.2em; color: var(--color-red); }",
    "</style>",
])


def _reason_link(rule):
    """The reason prose, linking to the rule's ref (the web equivalent of the
    terminal's OSC 8 hyperlink). Plain text when the rule has no ref."""
    reason = html.escape(rule["reason"])
    ref = rule.get("ref") or ""
    if ref:
        return f'<a href="{html.escape(ref)}" target="_blank" rel="noopener">{reason}</a>'
    return reason


def prompt_card(rule, section, extensions):
    """Approximate the Claude Code permission UI for one rule. Block rules
    render as the rejected tool result (red bullet + error, no confirmation);
    ask rules render the confirmation prompt with its Yes/No options."""
    name = html.escape(rule.get("name") or "")
    reason = html.escape(rule["reason"])

    if rule.get("target", "bash") == "file-content":
        ext = html.escape(extensions[0] if extensions else ".txt")
        tool = "Write"
        head = f"Write <code>script{ext}</code>"
        cmd = f'<span class="cw-prompt-dim">…file content matching “{name}”…</span>'
        bullet_arg = f"script{ext}"
    else:
        tool = "Bash"
        head = "Bash command"
        cmd = name
        bullet_arg = name

    if section == "block":
        # Mirror the engine's deny output: the plain `<name>: <reason> — <ref>`
        # form (Claude Code's error renderer strips OSC 8, so the ref stays a
        # bare URL rather than a hyperlink) plus the `[plugin:ClaudeWatch]` tag
        # the engine appends so a blocked command still shows its source.
        ref = rule.get("ref") or ""
        err = f"{name}: {reason}"
        if ref:
            err += f" — {html.escape(ref)}"
        return "\n".join([
            '<div class="cw-prompt cw-prompt-block">',
            f'  <div class="cw-prompt-deny"><span class="cw-prompt-bullet">●</span> <strong>{tool}</strong>({bullet_arg})</div>',
            f'  <div class="cw-prompt-denyerr">└ Error: {err} <span class="cw-prompt-dim">[plugin:ClaudeWatch]</span></div>',
            '</div>',
        ])

    return "\n".join([
        '<div class="cw-prompt cw-prompt-ask">',
        f'  <div class="cw-prompt-head">{head}</div>',
        f'  <div class="cw-prompt-cmd">{cmd}</div>',
        f'  <div class="cw-prompt-hook">Hook <strong>PreToolUse:{tool}</strong> requires confirmation for this command:</div>',
        f'  <div class="cw-prompt-msg">{name}: {_reason_link(rule)} <span class="cw-prompt-dim">[plugin:ClaudeWatch]</span></div>',
        "  <div class=\"cw-prompt-attr\">Edit the plugin's hooks.json to update hooks</div>",
        '  <div class="cw-prompt-q">Do you want to proceed?</div>',
        '  <div class="cw-prompt-opts"><span class="cw-prompt-cursor">❯</span> 1. Yes\n  2. No</div>',
        '</div>',
    ])


def prompts_section(config):
    rules = config["rules"]
    extensions = config.get("extensions") or []
    cards = [
        prompt_card(r, section, extensions)
        for section in ("block", "ask")
        for r in rules[section]
    ]
    return "\n\n".join(cards)


def write_file(site_dir, name, content):
    with open(os.path.join(site_dir, name), "w") as f:
        f.write(content)


def main():
    parse_rules_yml = load_parser()

    rules_dir = os.path.join(ROOT_DIR, "rules")
    docs_dir = os.path.join(ROOT_DIR, "docs")
    site_dir = os.path.join(docs_dir, "_site")

    if os.path.exists(site_dir):
        shutil.rmtree(site_dir)
    os.makedirs(site_dir)

    for name in os.listdir(docs_dir):
        src = os.path.join(docs_dir, name)
        if name.startswith("_"):
            continue
        dst = os.path.join(site_dir, name)
        if os.path.isdir(src):
            shutil.copytree(src, dst)
        elif os.path.isfile(src):
            shutil.copy2(src, dst)

    shutil.copy2(os.path.join(docs_dir, "_sidebar.md"), os.path.join(site_dir, "_sidebar.md"))

    # process each rule set
    rule_files = sorted(f for f in os.listdir(rules_dir) if f.endswith(".yml"))
    sections = []
    prompt_sections = []
    for rf in rule_files:
        src = os.path.join(rules_dir, rf)
        shutil.copy2(src, os.path.join(site_dir, rf))
        config = parse_rules_yml(src)
        label = config.get("name") or os.path.splitext(rf)[0]
        sections.append(f"## {label}\n\n{unified_table(config)}")
        prompt_sections.append(f"## {label}\n\n{prompts_section(config)}")

    write_file(site_dir, "rules.md", "\n".join([
        STATUS_STYLE,
        "",
        "# Rules",
        "",
        "Generated from rule files in `rules/`.",
        "",
        "> [!TIP]",
        "> Use the `/ClaudeWatch:rules` skill to interactively customize or extend these rules.",
        "",
        "\n\n".join(sections),
        "",
    ]))

    write_file(site_dir, "prompts.md", "\n".join([
        PROMPT_STYLE,
        "",
        "# Prompts",
        "",
        "How each rule surfaces in Claude Code — an approximation, generated "
        "from the rule files in `rules/`. An **ask** rule pauses for your "
        "confirmation before the command runs, with the reason linking to the "
        "rule's reference. A **block** rule rejects the command outright: Claude "
        "Code never prompts, and the rejected tool result shows the reason, the "
        "reference URL, and the source plugin.",
        "",
        "> [!TIP]",
        "> In the confirmation prompt the reason prose is a clickable [OSC 8 hyperlink](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda) to the rule's reference; set `CLAUDEWATCH_HYPERLINKS=off` for the plain `— <url>` form. A blocked command's error always shows the plain URL — Claude Code's error display strips the hyperlink.",
        "",
        "\n\n".join(prompt_sections),
        "",
    ]))

    print("docs/_site built")


if __name__ == "__main__":
    main()
