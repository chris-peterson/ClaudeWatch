default: test

# run the unattended test suite
test:
    bash tests/test-watchdog.sh

# regenerate all generated artifacts: shipyard projection + the watches-derived docs pages
generate:
    scripts/shipyard generate
    python3 build/gen-rules-doc.py

# validate source projects cleanly and preview the pending projection (no write)
check:
    scripts/shipyard generate --dry-run

# render the docs site: shipyard's standard pages + the watches-derived rules/prompts
docs:
    scripts/shipyard build-docs
    python3 build/gen-rules-doc.py

# preview the docs site locally
docs-preview: docs
    npx docsify-cli serve docs --open

# regenerate .claude-plugin/plugin.json from plugin.yml (the canonical descriptor)
plugin-json:
    scripts/shipyard gen-plugin-json

# resync plugin.yml suite.describe from the skills/rules/hooks sources
describe:
    scripts/shipyard gen-describe

# launch an interactive session with the local plugin loaded
try:
    claude --plugin-dir .

# launch an interactive session with the plugin loaded and open the rules skill
rules:
    claude --plugin-dir . "/ClaudeWatch:rules"
