default: test

# run the unattended test suite
test:
    bash tests/test-watchdog.sh

# regenerate all generated artifacts from source (describe, plugin.json, docs)
build: describe plugin-json docs

# verify committed generated artifacts (plugin.json, describe) match source
check:
    scripts/shipyard check

# regenerate the docsify rules/prompts site from the watches
docs:
    python3 build/gen-rules-doc.py

# preview the docs site locally
docs-preview: docs
    npx docsify-cli serve docs/_site --open

# regenerate .claude-plugin/plugin.json from plugin.yml (the canonical descriptor)
plugin-json:
    scripts/shipyard gen-plugin-json

# resync plugin.yml suite.describe from the skills/rules/hooks sources
describe:
    scripts/shipyard gen-describe

# install the git pre-commit hook that keeps generated artifacts in sync
install-hooks:
    cp scripts/hooks/pre-commit .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    @echo "installed .git/hooks/pre-commit"

# launch an interactive session with the local plugin loaded
try:
    claude --plugin-dir .

# launch an interactive session with the plugin loaded and open the rules skill
rules:
    claude --plugin-dir . "/ClaudeWatch:rules"
