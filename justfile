default: test

# run the unattended test suite
test:
    bash tests/test-watchdog.sh

# CI is the only writer of the projection; `git restore .` discards this.
# read what the project job would commit, without keeping anything
peek-projection:
    uvx --from 'git+https://github.com/chris-peterson/shipyard@v2' shipyard generate
    git --no-pager diff --stat

# render the docs site: shipyard's standard pages + the watches-derived rules/prompts
docs:
    uvx --from 'git+https://github.com/chris-peterson/shipyard@v2' shipyard build-docs
    python3 build/gen-rules-doc.py

# preview the docs site locally
docs-preview: docs
    npx docsify-cli serve docs --open

# launch an interactive session with the local plugin loaded
try:
    claude --plugin-dir .

# launch an interactive session with the plugin loaded and open the rules skill
rules:
    claude --plugin-dir . "/ClaudeWatch:rules"
