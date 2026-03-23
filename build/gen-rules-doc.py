#!/usr/bin/env python3
"""Generate docs/_site from rule sets and static docs (single source of truth)."""

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


def unified_table(config):
    rules = config["rules"]
    lines = ["| | Command | Reason | Ref |", "| --- | --- | --- | --- |"]
    for section, emoji in [("block", ":no_entry_sign:"), ("ask", ":raised_hand:")]:
        for r in rules[section]:
            raw_name = r.get("name", "").replace("|", "\\|")
            name = f"`{raw_name}`" if raw_name else ""
            reason = r["reason"].replace("|", "\\|")
            ref = f"[docs]({r['ref']})" if r["ref"] else ""
            lines.append(f"| {emoji} | {name} | {reason} | {ref} |")
    lines.append("")
    lines.append(":no_entry_sign: = blocked outright &nbsp;&nbsp; :raised_hand: = requires user confirmation")
    return "\n".join(lines)


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
    for rf in rule_files:
        src = os.path.join(rules_dir, rf)
        shutil.copy2(src, os.path.join(site_dir, rf))
        config = parse_rules_yml(src)
        label = config.get("name") or os.path.splitext(rf)[0]
        sections.append(f"## {label}\n\n{unified_table(config)}")

    write_file(site_dir, "rules.md", "\n".join([
        "# Default Rules",
        "",
        "Generated from rule files in `rules/`.",
        "",
        "> [!TIP]",
        "> Use the `/ClaudeWatch:rules` skill to interactively customize or extend these rules.",
        "",
        "\n\n".join(sections),
        "",
    ]))

    print("docs/_site built")


if __name__ == "__main__":
    main()
