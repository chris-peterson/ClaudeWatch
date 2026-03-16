default: test

# run the unattended test suite
test:
    bash tests/test-git-guard.sh

# launch an interactive session with the plugin loaded and open the configure skill
configure:
    claude --plugin-dir . "/git-guardian:configure"

# make a targeted rule change, e.g.: just guard "block 'add .'"
guard rule="":
    claude --plugin-dir . "/git-guardian:guard {{rule}}"
