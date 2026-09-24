#!/usr/bin/env bash
#
# install.sh - install my dev tools on whatever machine this is.
#
#   ./install.sh                 # do everything
#   ./install.sh uv pre-commit   # only the named targets
#   ./install.sh dotfiles        # copy dotfiles/shellrc into your shell rc
#   source ./install.sh dotfiles # ...and make the aliases live in this shell
#   ./install.sh --list          # show what is present and what is missing
#
# Targets: git, uv, pre-commit, docker, dotfiles
# Minimum versions are set in versions.conf.
#
# Every step is idempotent: anything already in place is skipped, so
# re-running this on an existing machine is safe. Config is copied into your
# home directory, not sourced from here, so this repo can be deleted after.

# Executed (./install.sh) or sourced (source ./install.sh)?
#
# A script cannot change the shell that launched it - it runs in a child
# process that exits - so `./install.sh dotfiles` can never make aliases live
# in your current terminal. Sourcing runs everything in THIS shell instead, so
# the rc reload at the end of the dotfiles step actually takes effect.
#
# Strict mode is therefore only switched on when executed: turning on
# `set -e` in someone's interactive shell would close their terminal on the
# next failed command.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _SOURCED=false
  set -euo pipefail
else
  _SOURCED=true
fi

# BASH_SOURCE, not $0: when sourced, $0 is the calling shell, not this file.
_self="${BASH_SOURCE[0]}"
_here="$(cd "$(dirname "$_self")" && pwd)"
# shellcheck source=lib/detect-machine.sh
source "$_here/lib/detect-machine.sh"

# Minimum versions live in versions.conf so there is one place to bump them.
# shellcheck source=versions.conf
source "$_here/versions.conf"

TOOLS=(git uv pre-commit docker)      # things we check for with `have`
TARGETS=("${TOOLS[@]}" dotfiles)      # everything ./install.sh can do

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  _bold=$'\e[1m'; _green=$'\e[32m'; _yellow=$'\e[33m'; _red=$'\e[31m'; _off=$'\e[0m'
else
  _bold=""; _green=""; _yellow=""; _red=""; _off=""
fi

step() { echo "${_bold}==>${_off} $*"; }
ok()   { echo "  ${_green}ok${_off}   $*"; }
skip() { echo "  ${_yellow}skip${_off} $*"; }
warn() { echo "  ${_red}warn${_off} $*" >&2; }

# ---------------------------------------------------------------------------
# git - the binary, then the shared profile
# ---------------------------------------------------------------------------

install_git() {
  if ! have git; then
    step "Installing git"
    pkg_install git
  fi

  local v
  v="$(version_of git)"
  if version_ge "$v" "$GIT_MIN"; then
    skip "git $v already installed (need >= $GIT_MIN)"
  else
    step "git $v is older than $GIT_MIN - upgrading"
    _upgrade_git
    v="$(version_of git)"
    if version_ge "$v" "$GIT_MIN"; then
      ok "git upgraded to $v"
    else
      warn "git is still $v; dotfiles/gitconfig needs >= $GIT_MIN"
      warn "  merge.conflictStyle=zdiff3 will abort merges until this is fixed"
    fi
  fi

  _git_profile
}

# Distro git is often years behind. Ubuntu's own git maintainers publish a
# current build in ppa:git-core/ppa, which is the supported way to get one.
_upgrade_git() {
  case "$DEV_OS" in
    macos)
      have brew || { warn "Homebrew needed to upgrade git on macOS"; return 1; }
      brew install git || brew upgrade git
      return 0
      ;;
    linux) ;;
    *) warn "Don't know how to upgrade git on $DEV_OS"; return 1 ;;
  esac

  case "$DEV_DISTRO" in
    ubuntu)
      pkg_install software-properties-common
      $DEV_SUDO add-apt-repository -y ppa:git-core/ppa
      $DEV_SUDO apt-get update
      $DEV_SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y git
      ;;
    debian)
      warn "No git-core PPA for Debian; try backports:"
      warn "  sudo apt-get -t \${DEV_CODENAME}-backports install git"
      return 1
      ;;
    *)
      # Rolling and semi-rolling distros generally ship a current git already.
      pkg_install git
      ;;
  esac
}

# The profile is split in two on purpose:
#   dotfiles/gitconfig  shared, committed, machine-independent
#   ~/.gitconfig        identity and machine-local overrides, never committed
_git_profile() {
  _gitconfig_include
  _gitconfig_identity
}

# The block goes at the TOP of ~/.gitconfig: git applies config in read order
# and the last value wins, so your own settings stay below it and keep
# overriding these shared defaults.
_gitconfig_include() {
  local src="$_here/dotfiles/gitconfig"
  local rc="$HOME/.gitconfig"

  [ -f "$src" ] || { warn "not found: $src"; return 1; }

  step "Copying dotfiles/gitconfig into $rc"
  _sync_block "$src" "$rc" "dotfiles/gitconfig" top
}

# Ask for identity only when it is missing, and only when there is a terminal
# to ask on (this script may run unattended during provisioning).
_gitconfig_identity() {
  local name email
  name="$(git config --global user.name || true)"
  email="$(git config --global user.email || true)"

  if [ -n "$name" ] && [ -n "$email" ]; then
    skip "git identity already set: $name <$email>"
    return 0
  fi

  if [ ! -t 0 ]; then
    warn "No terminal to prompt on. Set your identity with:"
    warn "  git config --global user.name  'Your Name'"
    warn "  git config --global user.email 'you@example.com'"
    return 0
  fi

  step "Setting your git identity (stored in $HOME/.gitconfig, not the repo)"
  if [ -z "$name" ]; then
    read -r -p "  Your name  : " name
    [ -n "$name" ] && git config --global user.name "$name"
  fi
  if [ -z "$email" ]; then
    read -r -p "  Your email : " email
    [ -n "$email" ] && git config --global user.email "$email"
  fi
  ok "identity set: $(git config --global user.name) <$(git config --global user.email)>"
}

# ---------------------------------------------------------------------------
# uv - https://docs.astral.sh/uv/
# ---------------------------------------------------------------------------

install_uv() {
  if have uv; then
    local v
    v="$(version_of uv)"
    if version_ge "$v" "$UV_MIN"; then
      skip "uv $v already installed (need >= $UV_MIN)"
      return 0
    fi
    step "uv $v is older than $UV_MIN - upgrading"
    if [ "$DEV_PKG" = brew ]; then brew upgrade uv; else uv self update; fi
    ok "uv upgraded to $(version_of uv)"
    return 0
  fi

  step "Installing uv"
  if [ "$DEV_PKG" = brew ]; then
    brew install uv
  else
    # Astral's official installer; drops uv in ~/.local/bin
    curl -LsSf https://astral.sh/uv/install.sh | sh
    _ensure_local_bin_on_path
  fi
  ok "uv installed ($(version_of uv))"
}

# ---------------------------------------------------------------------------
# pre-commit - installed as a uv tool so it gets its own isolated venv
# ---------------------------------------------------------------------------

install_pre_commit() {
  if have pre-commit; then
    local v
    v="$(version_of pre-commit)"
    if version_ge "$v" "$PRE_COMMIT_MIN"; then
      skip "pre-commit $v already installed (need >= $PRE_COMMIT_MIN)"
      return 0
    fi
    step "pre-commit $v is older than $PRE_COMMIT_MIN - upgrading"
    if have uv; then uv tool upgrade pre-commit; else brew upgrade pre-commit; fi
    ok "pre-commit upgraded to $(version_of pre-commit)"
    return 0
  fi

  step "Installing pre-commit"
  if have uv; then
    uv tool install pre-commit
    _ensure_local_bin_on_path
  elif [ "$DEV_PKG" = brew ]; then
    brew install pre-commit
  else
    warn "uv not found; install uv first (./install.sh uv)"
    return 1
  fi
  ok "pre-commit installed"
}

# ---------------------------------------------------------------------------
# docker
# ---------------------------------------------------------------------------

install_docker() {
  if have docker; then
    local v
    v="$(version_of docker)"
    if version_ge "$v" "$DOCKER_MIN"; then
      skip "docker $v already installed (need >= $DOCKER_MIN)"
    else
      warn "docker $v is older than $DOCKER_MIN - upgrade with your package manager"
    fi
    _docker_group_check
    return 0
  fi
  step "Installing docker"

  case "$DEV_OS" in
    macos)
      have brew || { warn "Homebrew needed to install docker on macOS"; return 1; }
      # CLI only, no Docker Desktop: colima supplies the daemon VM.
      brew install docker docker-compose colima
      ok "docker CLI + colima installed - start the daemon with: colima start"
      return 0
      ;;
    linux) ;;
    *) warn "Don't know how to install docker on $DEV_OS"; return 1 ;;
  esac

  case "$DEV_DISTRO:$DEV_DISTRO_LIKE" in
    debian:*|ubuntu:*|*:*debian*)
      _install_docker_debian
      ;;
    *)
      # Docker's convenience script covers the rest (fedora, centos, ...)
      step "Using Docker's convenience script for $DEV_DISTRO"
      curl -fsSL https://get.docker.com | $DEV_SUDO sh
      ;;
  esac

  $DEV_SUDO systemctl enable --now docker 2>/dev/null || true
  _docker_post_install
  ok "docker installed"
}

_install_docker_debian() {
  local codename="${DEV_CODENAME:-$(lsb_release -cs 2>/dev/null || echo stable)}"
  local distro_id="$DEV_DISTRO"
  # Derivatives (Linux Mint, Pop!_OS, ...) must use the Ubuntu/Debian repo.
  case "$distro_id" in
    ubuntu|debian) ;;
    *) case "$DEV_DISTRO_LIKE" in *ubuntu*) distro_id=ubuntu ;; *) distro_id=debian ;; esac ;;
  esac

  pkg_install ca-certificates curl gnupg

  $DEV_SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$distro_id/gpg" |
    $DEV_SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
  $DEV_SUDO chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$distro_id $codename stable" |
    $DEV_SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

  $DEV_SUDO apt-get update
  $DEV_SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

_docker_post_install() {
  if ! getent group docker >/dev/null 2>&1; then
    $DEV_SUDO groupadd docker
  fi
  if ! id -nG "$DEV_USER" | tr ' ' '\n' | grep -qx docker; then
    $DEV_SUDO usermod -aG docker "$DEV_USER"
    warn "Added $DEV_USER to the docker group - log out and back in for it to take effect"
  fi
}

_docker_group_check() {
  [ "$DEV_OS" = linux ] || return 0
  if ! id -nG "$DEV_USER" | tr ' ' '\n' | grep -qx docker; then
    warn "$DEV_USER is not in the docker group; run: sudo usermod -aG docker $DEV_USER"
  fi
}

# ---------------------------------------------------------------------------
# dotfiles
# ---------------------------------------------------------------------------

# Append one `source` line to ~/.bashrc rather than replacing the file, so the
# distro's default .bashrc keeps working.
#
# macOS defaults to zsh, so ~/.bashrc would never be read there; and a macOS
# bash *login* shell reads ~/.bash_profile rather than ~/.bashrc. So: wire into
# every rc file that already exists, plus the login shell's own rc even when it
# does not exist yet (a fresh macOS account often has no ~/.zshrc).
_rc_targets() {
  local candidates=("$HOME/.bashrc" "$HOME/.zshrc")
  [ "$DEV_OS" = macos ] && candidates+=("$HOME/.bash_profile")

  local found=() rc
  for rc in "${candidates[@]}"; do
    if [ -f "$rc" ]; then found+=("$rc"); fi
  done

  local login_rc=""
  case "${SHELL##*/}" in
    zsh)  login_rc="$HOME/.zshrc" ;;
    bash) login_rc="$HOME/.bashrc" ;;
  esac
  if [ -n "$login_rc" ] && [ ! -f "$login_rc" ]; then
    found+=("$login_rc")
  fi

  printf '%s\n' ${found[@]+"${found[@]}"}
}

install_dotfiles() {
  local src="$_here/dotfiles/shellrc"
  [ -f "$src" ] || { warn "not found: $src"; return 1; }

  step "Copying dotfiles/shellrc into your shell rc files"
  local rc
  while IFS= read -r rc; do
    [ -n "$rc" ] || continue
    _sync_block "$src" "$rc" "dotfiles/shellrc" bottom
  done < <(_rc_targets)

  _reload_shell_rc
  return 0
}

# The rc file the shell you are sitting in actually reads.
_current_shell_rc() {
  case "${SHELL##*/}" in
    zsh)  printf '%s/.zshrc'  "$HOME" ;;
    bash) printf '%s/.bashrc' "$HOME" ;;
    *)    printf '' ;;
  esac
}

# Make the aliases live now if we can, otherwise say exactly how.
_reload_shell_rc() {
  local rc
  rc="$(_current_shell_rc)"

  if [ -z "$rc" ] || [ ! -f "$rc" ]; then
    ok "open a new shell to pick up the aliases"
    return 0
  fi

  if [ "$_SOURCED" != true ]; then
    # We are a child process; anything we source dies with us.
    if [ "$_BLOCK_CREATED" = true ]; then
      # `src` ships inside the block we just wrote, so it does not exist in
      # the caller's shell yet. Long form this once.
      ok "run:  source $rc"
      ok "  from then on 'src' does it for you"
    else
      ok "run 'src' to pick up the changes in this shell"
    fi
    return 0
  fi

  # shellcheck disable=SC1090  # path is only known at runtime
  . "$rc"
  ok "reloaded $rc - aliases are live in this shell"
}

# ---------------------------------------------------------------------------
# managed blocks
#
# Config is COPIED into ~/.bashrc, ~/.zshrc and ~/.gitconfig rather than
# sourced/included from this repo, so the repo can be deleted afterwards and
# nothing breaks. The copy is fenced by marker comments:
#
#   # >>> setup-dev-env: dotfiles/shellrc >>>
#   ...contents...
#   # <<< setup-dev-env: dotfiles/shellrc <<<
#
# Re-running replaces what is between the markers, so editing a file here and
# re-running updates the machine without ever duplicating the block. Anything
# you write outside the markers is left untouched.
# ---------------------------------------------------------------------------

# Set when a block is written into a file that did not have one yet. That
# means `src` is not defined in the caller's shell either, so the advice at
# the end has to be the long `source <rc>` form exactly once.
_BLOCK_CREATED=false

_block_begin() { printf '# >>> setup-dev-env: %s >>>' "$1"; }
_block_end()   { printf '# <<< setup-dev-env: %s <<<' "$1"; }

# Strip the `source`/`[include]` pointers written by earlier versions of this
# script, so upgrading does not leave a dead reference to a deleted repo.
_strip_legacy_pointers() {
  awk '
    /^# added by setup-dev-env/                          { next }
    /^# Keep machine-local settings BELOW this include/  { next }
    /^\[include\]$/                                      { held = 1; next }
    /setup-dev-env\/dotfiles\//                          { held = 0; next }
    { if (held) { print "[include]"; held = 0 } print }
    END { if (held) print "[include]" }
  ' "$1"
}

# _sync_block <src> <dest> <name> [top|bottom]
#
# top    - block goes first, so the user's own settings sit below it and win
#          (git applies config in read order, last value wins)
# bottom - block goes last (default; fine for shell aliases)
_sync_block() {
  local src="$1" dest="$2" name="$3" pos="${4:-bottom}"
  local begin end before after
  begin="$(_block_begin "$name")"
  end="$(_block_end "$name")"

  before="$(mktemp)"; after="$(mktemp)"
  if [ -f "$dest" ]; then cp "$dest" "$before"; else : >"$before"; fi

  if grep -qF "$begin" "$before"; then
    # Replace whatever is currently between the markers.
    awk -v b="$begin" -v e="$end" -v f="$src" '
      index($0, b) == 1 {
        print
        while ((getline line < f) > 0) print line
        close(f)
        inblock = 1
        next
      }
      inblock && index($0, e) == 1 { inblock = 0; print; next }
      inblock { next }
      { print }
    ' "$before" >"$after"
  else
    _BLOCK_CREATED=true
    local body
    body="$(mktemp)"
    _strip_legacy_pointers "$before" >"$body"
    {
      if [ "$pos" = top ]; then
        printf '%s\n' "$begin"; cat "$src"; printf '%s\n\n' "$end"
        cat "$body"
      else
        cat "$body"
        printf '\n%s\n' "$begin"; cat "$src"; printf '%s\n' "$end"
      fi
    } >"$after"
    rm -f "$body"
  fi

  if cmp -s "$before" "$after"; then
    skip "$dest already has an up-to-date $name block"
    rm -f "$before" "$after"
    return 0
  fi

  mv "$after" "$dest"
  rm -f "$before"
  ok "wrote the $name block into $dest"
  return 0
}

# ---------------------------------------------------------------------------
# shared bits
# ---------------------------------------------------------------------------

# uv and uv-installed tools land in ~/.local/bin, which is not always on PATH.
_ensure_local_bin_on_path() {
  local bin="$HOME/.local/bin"
  [ -d "$bin" ] || return 0
  case ":$PATH:" in *":$bin:"*) ;; *) export PATH="$bin:$PATH" ;; esac

  local rc="$HOME/.bashrc"
  [ "${SHELL##*/}" = zsh ] && rc="$HOME/.zshrc"
  [ -f "$rc" ] || return 0
  if ! grep -qF '.local/bin' "$rc"; then
    # SC2016: $HOME and $PATH must stay literal - they are expanded by the
    # shell that later reads the rc file, not by us now.
    # shellcheck disable=SC2016
    printf '\n# added by setup-dev-env\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"$rc"
    warn "Added ~/.local/bin to PATH in $rc - open a new shell to pick it up"
  fi
}

# Print the header comment block as the usage text: skip the shebang, then
# every comment line until the first line that is not one. Deriving the range
# beats hardcoding line numbers, which go stale the moment the header changes.
_usage() {
  awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$_self"
}

_list() {
  echo "Machine: ${DEV_PRETTY_NAME:-$DEV_DISTRO} ($DEV_ARCH, $DEV_PKG)"
  echo
  local t v min
  for t in "${TOOLS[@]}"; do
    if ! have "$t"; then
      printf '  %-12s %smissing%s\n' "$t" "$_yellow" "$_off"
      continue
    fi
    v="$(version_of "$t")"
    # GIT_MIN, UV_MIN, PRE_COMMIT_MIN, DOCKER_MIN - name built from the tool.
    # tr rather than ${t^^} because macOS still ships bash 3.2, where the
    # ^^ upper-casing expansion is a syntax error.
    min="$(printf '%s' "$t" | tr 'a-z-' 'A-Z_')_MIN"
    min="${!min:-0}"
    if version_ge "$v" "$min"; then
      printf '  %-12s %s%-9s%s %s\n' "$t" "$_green" "$v" "$_off" "$(command -v "$t")"
    else
      printf '  %-12s %s%-9s%s too old, need >= %s\n' "$t" "$_red" "$v" "$_off" "$min"
    fi
  done

  local applied=() rc
  while IFS= read -r rc; do
    if [ -f "$rc" ] && grep -qF "$(_block_begin dotfiles/shellrc)" "$rc"; then
      applied+=("${rc/#$HOME/\~}")
    fi
  done < <(_rc_targets)
  local gc="$HOME/.gitconfig"
  if [ -f "$gc" ] && grep -qF "$(_block_begin dotfiles/gitconfig)" "$gc"; then
    applied+=("${gc/#$HOME/\~}")
  fi

  if [ ${#applied[@]} -gt 0 ]; then
    printf '  %-12s %sapplied%s   %s\n' "dotfiles" "$_green" "$_off" "${applied[*]}"
  else
    printf '  %-12s %snot applied%s\n' "dotfiles" "$_yellow" "$_off"
  fi
}

install_one() {
  case "$1" in
    git)        install_git ;;
    uv)         install_uv ;;
    pre-commit) install_pre_commit ;;
    docker)     install_docker ;;
    dotfiles)   install_dotfiles ;;
    *)          warn "Unknown target: $1 (known: ${TARGETS[*]})"; return 1 ;;
  esac
}

main() {
  case "${1:-}" in
    --list|-l) _list; return 0 ;;
    -h|--help) _usage; return 0 ;;
  esac

  local wanted=("$@")
  [ ${#wanted[@]} -gt 0 ] || wanted=("${TARGETS[@]}")

  step "Machine: ${DEV_PRETTY_NAME:-$DEV_DISTRO} ($DEV_ARCH, package manager: $DEV_PKG)"
  local t failed=()
  for t in "${wanted[@]}"; do
    install_one "$t" || failed+=("$t")
  done

  echo
  if [ ${#failed[@]} -gt 0 ]; then
    warn "Failed: ${failed[*]}"
    return 1
  fi
  step "Done."
}

main "$@"
