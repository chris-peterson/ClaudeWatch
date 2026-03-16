# rules.yml

Rules are defined in `rules.yml` at the plugin root. Each rule has:

- **name** — human-friendly label shown in tables (e.g. `git push --force`)
- **pattern** — Python regex matched anywhere in the command
- **reason** — shown in the block/ask message
- **ref** — link to git documentation

[rules.yml](rules.yml ':include :type=code yaml')

> [!TIP]
> Use the `/git-guardian:rules` skill to interactively view and edit rules.
