shipyard := "uvx --from 'git+https://github.com/chris-peterson/shipyard@v2' shipyard"

# What this is, and every recipe there is
[private]
default:
    @echo ""
    @echo "  ClaudeWatch screens every shell command against regex safety rules"
    @echo "  before it runs."
    @echo ""
    @just --list --unsorted --list-prefix '    ' --list-heading ''
    @echo ""
    @echo "  The installed plugin is off in this checkout, so editing the rules"
    @echo "  isn't screened by the rules being edited. --plugin-dir is the only"
    @echo "  way to exercise a change here."

# `.claude/settings.json` turns the installed plugin off here, so --plugin-dir is
# what loads the working tree's copy.
# Open an interactive session with the local plugin loaded
[group('try it out')]
try:
    claude --plugin-dir .

# Open a session with the plugin loaded and go straight to the rules skill
[group('try it out')]
rules:
    claude --plugin-dir . "/ClaudeWatch:rules"

# Run the unattended test suite
[group('check your work')]
test:
    bash tests/test-watchdog.sh

# Read what the projection job would commit, without keeping it; `git restore .` discards
[group('check your work')]
check:
    {{shipyard}} generate
    git --no-pager diff --stat

# plugin.yml's docs: pre_render: has shipyard run gen-rules-doc.py itself first
# Render the docs site: shipyard's standard pages + the watches-derived rules/prompts
[group('docs')]
docs:
    {{shipyard}} build-docs

# Preview the docs site locally
[group('docs')]
preview-docs: docs
    npx docsify-cli serve docs --open
