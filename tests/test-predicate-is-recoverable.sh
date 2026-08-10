#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

# Exercises the new `is_recoverable` predicate through the real rule engine,
# against a demo-only fixture rule set (fixtures/watch-is-recoverable-demo.yml)
# rather than any shipped rule in watches/ — no default rule references this
# predicate, so this file is what actually proves the predicate behaves as
# documented.
RULES="$SCRIPT_DIR/fixtures/watch-is-recoverable-demo.yml"
t() { run_test "$RULES" "$@"; }

echo "=== is_recoverable predicate ==="

# is_recoverable (unlike is_relative_to_cwd) checks the filesystem, so the
# "should allow" cases below need a real git-initialized temp repo — a merely
# symbolic cwd can't satisfy the recoverability check.
REPO_DIR="$(mktemp -d)"
UNTRACKED_DIR="$(mktemp -d)"
trap 'rm -rf "$REPO_DIR" "$UNTRACKED_DIR"' EXIT
git -C "$REPO_DIR" init -q
# git -C <dir> requires <dir> to actually exist (it chdir's before checking
# repo status) -- pre-create the subdirectory the test below targets.
mkdir -p "$REPO_DIR/src"

echo "--- in-tree AND git-tracked: allowed ---"
t "rm -r in-tree relative"      allow "{\"tool_name\":\"Bash\",\"cwd\":\"$REPO_DIR\",\"tool_input\":{\"command\":\"rm -r old-dir\"}}"
t "rm -r in-tree subdir"        allow "{\"tool_name\":\"Bash\",\"cwd\":\"$REPO_DIR\",\"tool_input\":{\"command\":\"rm -r src/legacy\"}}"
t "rm -r in-tree absolute"      allow "{\"tool_name\":\"Bash\",\"cwd\":\"$REPO_DIR\",\"tool_input\":{\"command\":\"rm -r $REPO_DIR/build\"}}"

echo "--- the actual gap this predicate closes: in-tree but NOT git/chezmoi-tracked still prompts ---"
# A bare, non-version-controlled working directory (e.g. a VS Code workspace
# root whose children are individually git repos, but the root itself isn't)
# must NOT be silently exempted just because the target is spatially "under
# cwd" -- is_relative_to_cwd alone would allow this; is_recoverable does not.
t "rm -r in-tree but untracked" ask "{\"tool_name\":\"Bash\",\"cwd\":\"$UNTRACKED_DIR\",\"tool_input\":{\"command\":\"rm -r old-dir\"}}"

echo "--- out-of-tree still prompts, same as is_relative_to_cwd ---"
t "rm -r out-of-tree absolute"  ask "{\"tool_name\":\"Bash\",\"cwd\":\"$REPO_DIR\",\"tool_input\":{\"command\":\"rm -r /etc/foo\"}}"

print_results
