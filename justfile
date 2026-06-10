default: test

# run the unattended test suite
test:
    bash tests/test-watchdog.sh

# regenerate .claude-plugin/plugin.json from plugin.yml (the canonical descriptor)
plugin-json:
    python3 scripts/gen-plugin-json.py

# verify plugin.json is in sync with plugin.yml (used by CI and the pre-commit hook)
plugin-json-check:
    python3 scripts/gen-plugin-json.py --check

# install the git pre-commit hook that keeps plugin.json in sync with plugin.yml
install-hooks:
    cp scripts/hooks/pre-commit .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    @echo "installed .git/hooks/pre-commit"

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
