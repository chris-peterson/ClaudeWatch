#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

# Exercises the `is_recoverable` predicate ([RL-18]) through the real rule
# engine, against a demo-only fixture rule set
# (fixtures/watch-is-recoverable-demo.yml) rather than any shipped rule in
# watches/ — no default rule references this predicate, so this file is what
# proves it behaves as documented.
#
# The cases below separate the two axes the predicate is about: whether a
# target is under cwd (what is_in_project_tree already answers) and whether
# git could restore it (what this predicate adds). Swapping the fixture to
# is_in_project_tree must turn the "not restorable" cases red — that is the
# difference this file exists to hold.
RULES="$SCRIPT_DIR/fixtures/watch-is-recoverable-demo.yml"
t() { run_test "$RULES" "$@"; }

echo "=== is_recoverable predicate ==="

# The predicate reads the filesystem, so these need real directories: a git
# repo with an actual commit, and a plain directory that is not a repo.
REPO_DIR="$(mktemp -d)"
NON_REPO_DIR="$(mktemp -d)"
trap 'rm -rf "$REPO_DIR" "$NON_REPO_DIR" "${SUB_DIR:-}"' EXIT

git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email watchdog@test
git -C "$REPO_DIR" config user.name watchdog

# Tracked and committed: git can restore it.
mkdir -p "$REPO_DIR/tracked/nested"
echo committed > "$REPO_DIR/tracked/keep.txt"
echo committed > "$REPO_DIR/tracked/nested/keep.txt"
# Tracked and committed, then edited without committing: the delete takes the
# edit with it, and no amount of git history brings that back.
mkdir -p "$REPO_DIR/edited"
echo committed > "$REPO_DIR/edited/f.txt"
# Tracked, but holding one file nobody committed: the stray is lost with it.
mkdir -p "$REPO_DIR/mixed"
echo committed > "$REPO_DIR/mixed/keep.txt"
echo 'ignored-dir/' > "$REPO_DIR/.gitignore"
git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -qm "seed"
echo stray > "$REPO_DIR/mixed/stray.txt"
echo 'edited, never committed' > "$REPO_DIR/edited/f.txt"

# A submodule with uncommitted work inside it. The superproject's index records
# only the commit it points at, so nothing the outer repo can ask reaches in.
SUB_DIR="$(mktemp -d)"
git -C "$SUB_DIR" init -q
git -C "$SUB_DIR" config user.email watchdog@test
git -C "$SUB_DIR" config user.name watchdog
echo v1 > "$SUB_DIR/lib.txt"
git -C "$SUB_DIR" add -A
git -C "$SUB_DIR" commit -qm "sub seed"
git -C "$REPO_DIR" -c protocol.file.allow=always submodule add -q "$SUB_DIR" vendor 2>/dev/null
git -C "$REPO_DIR" commit -qm "add submodule" >/dev/null 2>&1
echo 'uncommitted inside the submodule' > "$REPO_DIR/vendor/scratch.txt"

# Never committed, and ignored: nothing behind either one.
mkdir -p "$REPO_DIR/untracked"
echo scratch > "$REPO_DIR/untracked/scratch.txt"
mkdir -p "$REPO_DIR/ignored-dir"
echo build-output > "$REPO_DIR/ignored-dir/artifact.bin"

# A plain directory that is not a git repo, standing in for the workspace root
# whose children are individually repos but which is not one itself.
mkdir -p "$NON_REPO_DIR/project"
echo unversioned > "$NON_REPO_DIR/project/notes.txt"

in_repo() { printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO_DIR" "$1"; }
in_bare() { printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$NON_REPO_DIR" "$1"; }

echo "--- tracked and fully committed: git can restore it, no prompt ---"
t "tracked dir, relative"   allow "$(in_repo 'rm -r tracked')"
t "tracked dir, nested"     allow "$(in_repo 'rm -r tracked/nested')"
t "tracked dir, absolute"   allow "$(in_repo "rm -r $REPO_DIR/tracked")"

echo "--- under cwd but NOT restorable: the gap this predicate closes ---"
# is_in_project_tree allows every one of these; is_recoverable must not.
t "never committed"         ask "$(in_repo 'rm -r untracked')"
t "gitignored"              ask "$(in_repo 'rm -r ignored-dir')"
t "does not exist"          ask "$(in_repo 'rm -r no-such-dir')"
t "tracked but holds stray" ask "$(in_repo 'rm -r mixed')"
t "tracked, edit uncommitted" ask "$(in_repo 'rm -r edited')"
t "submodule with work"       ask "$(in_repo 'rm -r vendor')"
t "cwd is not a repo"       ask "$(in_bare 'rm -r project')"

echo "--- multiple targets: one unrecoverable target blocks the exemption ---"
t "all restorable"          allow "$(in_repo 'rm -r tracked mixed/keep.txt')"
t "one not restorable"      ask   "$(in_repo 'rm -r tracked untracked')"

echo "--- the git probe follows the project root, not cwd ---"
# is_in_project_tree accepts a target under CLAUDE_PROJECT_DIR while cwd is
# elsewhere ([RL-16]); the recoverability check has to ask that repo, not
# whatever repo cwd happens to sit in — otherwise it declines every delete the
# second root exists to allow.
export CLAUDE_PROJECT_DIR="$REPO_DIR"
t "tracked, cwd outside the repo"  allow "$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"rm -r %s/tracked"}}' "$NON_REPO_DIR" "$REPO_DIR")"
t "untracked, cwd outside"         ask   "$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"rm -r %s/untracked"}}' "$NON_REPO_DIR" "$REPO_DIR")"
unset CLAUDE_PROJECT_DIR

echo "--- outside cwd still prompts, same as is_in_project_tree ---"
t "absolute out-of-tree"    ask "$(in_repo 'rm -r /etc/foo')"
t "parent escape"           ask "$(in_repo 'rm -r ../elsewhere')"

print_results
