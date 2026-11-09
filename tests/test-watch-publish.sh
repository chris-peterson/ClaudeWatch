#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../watches/watch-publish.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-publish ==="

echo "--- block: unpublish / yank ---"
t "npm unpublish ver"    block '{"tool_name":"Bash","tool_input":{"command":"npm unpublish left-pad@1.3.0"}}'
t "npm unpublish --force" block '{"tool_name":"Bash","tool_input":{"command":"npm unpublish left-pad --force"}}'
t "pnpm unpublish"       block '{"tool_name":"Bash","tool_input":{"command":"pnpm unpublish pkg@1.0.0"}}'
t "yarn npm unpublish"   block '{"tool_name":"Bash","tool_input":{"command":"yarn npm unpublish"}}'
t "gem yank"             block '{"tool_name":"Bash","tool_input":{"command":"gem yank mygem -v 1.0.0"}}'
t "npm unpublish --dry-run" allow '{"tool_name":"Bash","tool_input":{"command":"npm unpublish left-pad@1.3.0 --dry-run"}}'
t "npm unpublish --help" allow '{"tool_name":"Bash","tool_input":{"command":"npm unpublish --help"}}'

echo "--- ask: publish ---"
t "npm publish"          ask   '{"tool_name":"Bash","tool_input":{"command":"npm publish"}}'
t "npm publish --tag"    ask   '{"tool_name":"Bash","tool_input":{"command":"npm publish --tag next --access public"}}'
t "pnpm publish"         ask   '{"tool_name":"Bash","tool_input":{"command":"pnpm publish --no-git-checks"}}'
t "yarn npm publish"     ask   '{"tool_name":"Bash","tool_input":{"command":"yarn npm publish"}}'
t "npm publish --dry-run" allow '{"tool_name":"Bash","tool_input":{"command":"npm publish --dry-run"}}'

echo "--- allow: other registry commands ---"
t "npm view"             allow '{"tool_name":"Bash","tool_input":{"command":"npm view left-pad versions"}}'
t "npm pack"             allow '{"tool_name":"Bash","tool_input":{"command":"npm pack"}}'
t "gem list"             allow '{"tool_name":"Bash","tool_input":{"command":"gem list"}}'
t "npm run publish-docs" allow '{"tool_name":"Bash","tool_input":{"command":"npm run publish-docs"}}'

print_results
