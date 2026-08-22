shipyard := "uvx --from 'git+https://github.com/chris-peterson/shipyard@v2' shipyard"

default: test

# run the unattended test suite
test:
    bash tests/test-watchdog.sh

# CI is the only writer of the projection; `git restore .` discards this.
# read what the project job would commit, without keeping anything
peek-projection:
    python3 build/gen-rules-doc.py
    {{shipyard}} generate
    git --no-pager diff --stat

# render the docs site: the watches-derived rules/prompts + shipyard's standard pages
docs:
    python3 build/gen-rules-doc.py
    {{shipyard}} build-docs

# preview the docs site locally
docs-preview: docs
    npx docsify-cli serve docs --open

# launch an interactive session with the local plugin loaded
try:
    claude --plugin-dir .

# launch an interactive session with the plugin loaded and open the rules skill
rules:
    claude --plugin-dir . "/ClaudeWatch:rules"
