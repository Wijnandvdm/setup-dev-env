# setup-dev-env

Gets a fresh machine to a working dev setup: detects what it is running on,
installs the tools, writes my shell and git config into `$HOME`.

## Quick start

```bash
git clone <this repo> ~/repos/setup-dev-env
cd ~/repos/setup-dev-env

$EDITOR versions.conf           # minimum versions — the one file you tune
bash install.sh                 # everything
source ./install.sh dotfiles    # ...and make the aliases live in this shell
```

Then delete the repo if you like — nothing points back at it.

`bash install.sh git uv` runs only those targets, `bash install.sh --list`
shows what is present. Targets: `git` (install/upgrade, profile, identity),
`uv`, `pre-commit` (as a uv tool), `docker` (no Desktop; colima on macOS),
`dotfiles`. All idempotent — re-running skips what is already in place.

## Config is copied, not linked

Contents are copied into `~/.bashrc`, `~/.zshrc` and `~/.gitconfig` between
`# >>> setup-dev-env: ... >>>` markers, so the machine survives deleting this
repo. Re-running replaces the block; anything outside it is untouched. Edit a
file here, re-run `bash install.sh <target>`, then `src`.

The git block sits at the *top* of `~/.gitconfig` so your own settings below
it still win. Identity lives there too, and is never committed.

[`versions.conf`](versions.conf) holds every minimum. `GIT_MIN=2.38` is a hard
floor, not taste: `merge.conflictStyle=zdiff3` aborts every merge on older git.

## Layout

```
install.sh              targets, version checks, marker-block writer
lib/detect-machine.sh   machine detection; also sourceable as a library
dotfiles/shellrc        aliases + `src`, shared by bash and zsh
dotfiles/gitconfig      git defaults, each one documented
```

Keep `shellrc` portable — aliases and POSIX-ish functions only, or it breaks
the other shell. `pre-commit run --all-files` runs shellcheck over the lot.
