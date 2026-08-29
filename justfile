shipyard := "uvx --from 'git+https://github.com/chris-peterson/shipyard@v2' shipyard"

default: test

# run the unattended test suite
test:
    bash tests/test-watchdog.sh

# read what the projection job would commit, without keeping it; `git restore .` discards
check:
    {{shipyard}} generate
    git --no-pager diff --stat

# plugin.yml's docs: pre_render: has shipyard run gen-rules-doc.py itself first
# render the docs site: shipyard's standard pages + the watches-derived rules/prompts
docs:
    {{shipyard}} build-docs

# preview the docs site locally
preview-docs: docs
    npx docsify-cli serve docs --open

# launch an interactive session with the local plugin loaded
try:
    claude --plugin-dir .

# launch an interactive session with the plugin loaded and open the rules skill
rules:
    claude --plugin-dir . "/ClaudeWatch:rules"
