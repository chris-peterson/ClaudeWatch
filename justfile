default: test

# run the unattended test suite
test:
    bash tests/test-watchdog.sh

# regenerate docs from rules
docs:
    python3 build/gen-rules-doc.py

# preview docs site locally
docs-preview: docs
    npx docsify-cli serve docs/_site --open

# launch an interactive session with the local plugin loaded
try:
    claude --plugin-dir .

# launch an interactive session with the plugin loaded and open the rules skill
rules:
    claude --plugin-dir . "/ClaudeWatch:rules"
