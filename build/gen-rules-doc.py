#!/usr/bin/env python3
"""Generate the watches-derived docs pages (rules.md, prompts.md) into docs/.

shipyard's `build-docs` renders the standard pages (skills, prose rules, SPEC →
spec.md, plugin-docs.json). This adds the two pages built from `watches/*.yml`
that shipyard can't produce — the block/ask reference tables and the permission-
prompt gallery; both write into the `docs/` publish root.

Run this BEFORE any shipyard command that renders or checks docs/ (`build-docs`,
or `generate`, which calls it internally) — `docs/README.md` and
`docs/_sidebar.md` link to `/rules` and `/prompts`, and shipyard link-checks the
whole docs/ tree at the end of its own run. Those two pages have to already be
on disk or the check fails them as dead links.
"""

import html
import os

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
# prompt (purple top rule, Yes/No options) and a `block` rejected-tool-result
# line (red bullet, red error plus the `[plugin:ClaudeWatch]` tag the engine
# appends on deny). Both carry the canonical `— <ref>` URL; on the web page it
# is clickable, which the terminal's plain text is not.
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
    ".cw-prompt-msg a { color: inherit; text-decoration: underline; }",
    ".cw-prompt-attr { color: var(--color-comment); }",
    ".cw-prompt-q { margin-top: 0.9em; color: var(--color-foreground); }",
    ".cw-prompt-opts { color: var(--color-comment); }",
    ".cw-prompt-cursor { color: var(--color-purple); font-weight: 700; }",
    ".cw-prompt-deny { color: var(--color-foreground); }",
    ".cw-prompt-bullet { color: var(--color-red); }",
    ".cw-prompt-denyerr { padding-left: 2ch; margin-top: 0.2em; color: var(--color-red); }",
    "</style>",
])


def _reason_with_ref(rule):
    """The engine's canonical `<reason> — <ref>`, with the URL clickable."""
    reason = html.escape(rule["reason"])
    ref = rule.get("ref") or ""
    if not ref:
        return reason
    url = html.escape(ref)
    return f'{reason} — <a href="{url}" target="_blank" rel="noopener">{url}</a>'


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
        # Mirror the engine's deny output: `<name>: <reason> — <ref>` plus the
        # `[plugin:ClaudeWatch]` tag the engine appends so a blocked command
        # still shows its source.
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
        f'  <div class="cw-prompt-msg">{name}: {_reason_with_ref(rule)} <span class="cw-prompt-dim">[plugin:ClaudeWatch]</span></div>',
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


def write_file(docs_dir, name, content):
    with open(os.path.join(docs_dir, name), "w") as f:
        f.write(content)


def main():
    parse_rules_yml = load_parser()

    rules_dir = os.path.join(ROOT_DIR, "watches")
    docs_dir = os.path.join(ROOT_DIR, "docs")

    rule_files = sorted(f for f in os.listdir(rules_dir) if f.endswith(".yml"))
    sections = []
    prompt_sections = []
    for rf in rule_files:
        config = parse_rules_yml(os.path.join(rules_dir, rf))
        label = config.get("name") or os.path.splitext(rf)[0]
        sections.append(f"## {label}\n\n{unified_table(config)}")
        prompt_sections.append(f"## {label}\n\n{prompts_section(config)}")

    write_file(docs_dir, "rules.md", "\n".join([
        STATUS_STYLE,
        "",
        "# Rules",
        "",
        "Generated from rule files in `watches/`.",
        "",
        "> [!TIP]",
        "> Use the `/ClaudeWatch:rules` skill to interactively customize or extend these rules.",
        "",
        "\n\n".join(sections),
        "",
    ]))

    write_file(docs_dir, "prompts.md", "\n".join([
        PROMPT_STYLE,
        "",
        "# Prompts",
        "",
        "How each rule surfaces in Claude Code — an approximation, generated "
        "from the rule files in `watches/`. An **ask** rule pauses for your "
        "confirmation before the command runs and shows the reason with its "
        "reference URL. A **block** rule rejects the command outright: Claude "
        "Code never prompts, and the rejected tool result shows the reason, the "
        "reference URL, and the source plugin.",
        "",
        "\n\n".join(prompt_sections),
        "",
    ]))

    print("docs/rules.md and docs/prompts.md built")


if __name__ == "__main__":
    main()
