#!/usr/bin/env bash
#
# install.sh - install my dev tools on whatever machine this is.
#
#   ./install.sh                 # do everything
#   ./install.sh uv pre-commit   # only the named targets
#   ./install.sh dotfiles        # wire dotfiles/shellrc into your shell rc
#   ./install.sh --list          # show what is present and what is missing
#
# Targets: git, uv, pre-commit, docker, dotfiles
# Minimum versions are set in versions.conf.
#
# Every step is idempotent: anything already in place is skipped, so
# re-running this on an existing machine is safe.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Put the [include] at the TOP of ~/.gitconfig. Git applies config in read
# order and the last value wins, so anything already in ~/.gitconfig ends up
# below the include and keeps overriding the shared defaults.
_gitconfig_include() {
  local src="$_here/dotfiles/gitconfig"
  local rc="$HOME/.gitconfig"

  [ -f "$src" ] || { warn "not found: $src"; return 1; }

  if [ -f "$rc" ] && grep -qF 'dotfiles/gitconfig' "$rc"; then
    skip "$rc already includes dotfiles/gitconfig"
    return 0
  fi

  step "Including dotfiles/gitconfig from $rc"
  local tmp
  tmp="$(mktemp)"
  {
    printf '# added by setup-dev-env: shared defaults.\n'
    printf '# Keep machine-local settings BELOW this include so they win.\n'
    printf '[include]\n\tpath = %s\n' "$src"
  } >"$tmp"
  if [ -f "$rc" ]; then
    printf '\n' >>"$tmp"
    cat "$rc" >>"$tmp"
    cp "$rc" "$rc.setupbak"
    ok "backed up your previous config to $rc.setupbak"
  fi
  mv "$tmp" "$rc"
  ok "included - your existing settings were kept and still take precedence"
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

  local rc changed=0
  while IFS= read -r rc; do
    [ -n "$rc" ] || continue

    # Migrate the line written before shellrc was renamed from bashrc.
    if [ -f "$rc" ] && grep -qF 'dotfiles/bashrc' "$rc"; then
      sed -i.setupbak 's#dotfiles/bashrc#dotfiles/shellrc#g' "$rc"
      rm -f "$rc.setupbak"
      ok "updated the old dotfiles/bashrc reference in $rc"
      continue
    fi

    if [ -f "$rc" ] && grep -qF 'dotfiles/shellrc' "$rc"; then
      skip "$rc already sources dotfiles/shellrc"
      continue
    fi

    step "Sourcing dotfiles/shellrc from $rc"
    {
      printf '\n# added by setup-dev-env\n'
      printf '[ -f "%s" ] && . "%s"\n' "$src" "$src"
    } >>"$rc"
    ok "wired into $rc"
    changed=1
  done < <(_rc_targets)

  if [ "$changed" -eq 1 ]; then
    ok "open a new shell to pick up the aliases"
  fi
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

  local linked=() rc
  while IFS= read -r rc; do
    if [ -f "$rc" ] && grep -qF 'dotfiles/shellrc' "$rc"; then
      linked+=("${rc/#$HOME/\~}")
    fi
  done < <(_rc_targets)

  if [ ${#linked[@]} -gt 0 ]; then
    printf '  %-12s %slinked%s     %s\n' "dotfiles" "$_green" "$_off" "${linked[*]}"
  else
    printf '  %-12s %snot linked%s\n' "dotfiles" "$_yellow" "$_off"
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
    -h|--help) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
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
