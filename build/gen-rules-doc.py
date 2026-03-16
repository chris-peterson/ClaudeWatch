#!/usr/bin/env python3
"""Generate docs/_site from rules.yml and static docs (single source of truth)."""

import os
import shutil
import sys

from importlib.util import spec_from_file_location, module_from_spec

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)


def load_parser():
    spec = spec_from_file_location("git_guard", os.path.join(ROOT_DIR, "scripts", "git-guard.py"))
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.parse_rules_yml


def rule_table(rules):
    lines = ["| Pattern | Reason | Ref |", "| --- | --- | --- |"]
    for r in rules:
        pattern = f"`{r['pattern'].replace('|', '\\|')}`"
        ref = f"[docs]({r['ref']})" if r["ref"] else ""
        lines.append(f"| {pattern} | {r['reason']} | {ref} |")
    return "\n".join(lines)


def write_file(site_dir, name, content):
    with open(os.path.join(site_dir, name), "w") as f:
        f.write(content)


def main():
    parse_rules_yml = load_parser()
    rules = parse_rules_yml(os.path.join(ROOT_DIR, "rules.yml"))

    docs_dir = os.path.join(ROOT_DIR, "docs")
    site_dir = os.path.join(docs_dir, "_site")

    if os.path.exists(site_dir):
        shutil.rmtree(site_dir)
    os.makedirs(site_dir)

    for name in os.listdir(docs_dir):
        src = os.path.join(docs_dir, name)
        if name.startswith("_") or not os.path.isfile(src):
            continue
        shutil.copy2(src, os.path.join(site_dir, name))

    shutil.copy2(os.path.join(docs_dir, "_sidebar.md"), os.path.join(site_dir, "_sidebar.md"))
    shutil.copy2(os.path.join(ROOT_DIR, "rules.yml"), os.path.join(site_dir, "rules.yml"))

    write_file(site_dir, "rules.md", "\n".join([
        "# Default Rules",
        "",
        "Generated from [`rules.yml`](https://github.com/chris-peterson/git-guardian/blob/main/rules.yml).",
        "",
        "> [!TIP]",
        "> Use the `/git-guardian:rules` skill to interactively customize or extend these rules.",
        "",
    ]))

    write_file(site_dir, "block.md", "\n".join([
        "# Block Rules",
        "",
        "These commands are **rejected outright** — the agent cannot run them.",
        "",
        rule_table(rules["block"]),
        "",
    ]))

    write_file(site_dir, "ask.md", "\n".join([
        "# Ask Rules",
        "",
        "These commands **require user confirmation** before the agent can proceed.",
        "",
        rule_table(rules["ask"]),
        "",
    ]))

    print("docs/_site built")


if __name__ == "__main__":
    main()
