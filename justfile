default: test

# run the unattended test suite
test:
    bash tests/test-git-guard.sh

# regenerate docs from rules.yml
docs:
    python3 build/gen-rules-doc.py

# preview docs site locally
docs-preview: docs
    npx docsify-cli serve docs/_site --open

# launch an interactive session with the plugin loaded and open the rules skill
rules:
    claude --plugin-dir . "/git-guardian:rules"
