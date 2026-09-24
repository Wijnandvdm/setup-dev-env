#!/usr/bin/env bash
#
# detect-machine.sh - work out what kind of machine we are running on.
#
# Two ways to use it:
#
#   ./lib/detect-machine.sh            # human-readable report
#   ./lib/detect-machine.sh --json     # same facts as JSON
#
#   source lib/detect-machine.sh       # sets DEV_* vars + helpers, prints nothing
#
# When sourced it defines these variables:
#
#   DEV_OS            linux | macos | windows | unknown
#   DEV_DISTRO        ubuntu | debian | fedora | arch | alpine | macos | ...
#   DEV_DISTRO_LIKE   family the distro belongs to, e.g. debian  (may be empty)
#   DEV_VERSION_ID    22.04
#   DEV_CODENAME      jammy                                      (may be empty)
#   DEV_PRETTY_NAME   Ubuntu 22.04.4 LTS
#   DEV_ARCH          x86_64 | arm64 | armv7 | ...   (normalised)
#   DEV_KERNEL        5.15.0-116-generic
#   DEV_PKG           apt | dnf | yum | pacman | zypper | apk | brew | none
#   DEV_VIRT          none | kvm | oracle | vmware | docker | wsl | ...
#   DEV_IS_VM         true | false
#   DEV_IS_CONTAINER  true | false
#   DEV_IS_WSL        true | false
#   DEV_HAS_GUI       true | false
#   DEV_SUDO          "sudo" | ""   (prefix for commands needing root)
#   DEV_HOSTNAME      hostname
#   DEV_USER          current user
#
# ...and these helpers:
#
#   have <cmd>                  true if <cmd> is on PATH
#   version_of <cmd>            the tool's version number
#   version_ge <have> <want>    true if <have> is at least <want>
#   pkg_install <pkg>...        install packages with the detected manager
#   pkg_refresh                 refresh package lists (once per run)
#   require_linux / require_macos
#
# Strict mode is only enabled when the script is executed directly, so that
# sourcing it never changes the calling shell's options.

# ---------------------------------------------------------------------------
# detection
# ---------------------------------------------------------------------------

_detect_os() {
  case "$(uname -s)" in
    Linux)              DEV_OS=linux ;;
    Darwin)             DEV_OS=macos ;;
    CYGWIN*|MINGW*|MSYS*) DEV_OS=windows ;;
    *)                  DEV_OS=unknown ;;
  esac
}

_detect_arch() {
  DEV_KERNEL="$(uname -r)"
  case "$(uname -m)" in
    x86_64|amd64)   DEV_ARCH=x86_64 ;;
    aarch64|arm64)  DEV_ARCH=arm64 ;;
    armv7l|armv7)   DEV_ARCH=armv7 ;;
    i386|i686)      DEV_ARCH=x86 ;;
    *)              DEV_ARCH="$(uname -m)" ;;
  esac
}

# Echo one key from /etc/os-release, unquoted. Runs in a subshell, so the
# file's other keys never reach the caller's environment.
_os_release_get() (
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || exit 0
  printf '%s' "${!1:-}"
)

_detect_distro() {
  DEV_DISTRO=unknown
  DEV_DISTRO_LIKE=""
  DEV_VERSION_ID=""
  DEV_CODENAME=""
  DEV_PRETTY_NAME=""

  if [ "$DEV_OS" = macos ]; then
    DEV_DISTRO=macos
    DEV_DISTRO_LIKE=darwin
    DEV_VERSION_ID="$(sw_vers -productVersion 2>/dev/null || echo "")"
    DEV_PRETTY_NAME="macOS ${DEV_VERSION_ID}"
    return
  fi

  if [ -r /etc/os-release ]; then
    # Read it in a subshell so os-release's many keys (NAME, VERSION, HOME_URL,
    # ...) do not leak into the shell that sourced us.
    DEV_DISTRO="$(_os_release_get ID)"
    DEV_DISTRO_LIKE="$(_os_release_get ID_LIKE)"
    DEV_VERSION_ID="$(_os_release_get VERSION_ID)"
    DEV_CODENAME="$(_os_release_get VERSION_CODENAME)"
    DEV_PRETTY_NAME="$(_os_release_get PRETTY_NAME)"
    [ -n "$DEV_DISTRO" ] || DEV_DISTRO=unknown
    [ -n "$DEV_PRETTY_NAME" ] || DEV_PRETTY_NAME="$DEV_DISTRO $DEV_VERSION_ID"
  elif [ -r /etc/debian_version ]; then
    DEV_DISTRO=debian
    DEV_DISTRO_LIKE=debian
    DEV_VERSION_ID="$(cat /etc/debian_version)"
    DEV_PRETTY_NAME="Debian $DEV_VERSION_ID"
  fi
}

# Is this a container, a VM, or bare metal?
_detect_virt() {
  DEV_VIRT=none
  DEV_IS_CONTAINER=false
  DEV_IS_VM=false
  DEV_IS_WSL=false

  if [ -n "${WSL_DISTRO_NAME:-}" ] ||
     { [ -r /proc/version ] && grep -qiE 'microsoft|wsl' /proc/version; }; then
    DEV_VIRT=wsl
    DEV_IS_WSL=true
    return
  fi

  if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    DEV_IS_CONTAINER=true
    DEV_VIRT=$([ -f /run/.containerenv ] && echo podman || echo docker)
    return
  fi

  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local v
    v="$(systemd-detect-virt 2>/dev/null || true)"
    [ -n "$v" ] && DEV_VIRT="$v"
  elif [ "$DEV_OS" = linux ] && [ -r /sys/class/dmi/id/product_name ]; then
    case "$(cat /sys/class/dmi/id/product_name)" in
      *VirtualBox*)      DEV_VIRT=oracle ;;
      *VMware*)          DEV_VIRT=vmware ;;
      *KVM*|*QEMU*)      DEV_VIRT=kvm ;;
      *Virtual\ Machine*) DEV_VIRT=microsoft ;;
    esac
  fi

  case "$DEV_VIRT" in
    none|"")                       DEV_VIRT=none ;;
    docker|podman|lxc|lxc-libvirt|systemd-nspawn|containerd)
                                   DEV_IS_CONTAINER=true ;;
    *)                             DEV_IS_VM=true ;;
  esac
}

# First package manager found wins. On macOS prefer brew.
_detect_pkg() {
  DEV_PKG=none
  local candidates
  if [ "$DEV_OS" = macos ]; then
    candidates="brew port"
  else
    candidates="apt-get dnf yum pacman zypper apk brew"
  fi
  local c
  for c in $candidates; do
    if command -v "$c" >/dev/null 2>&1; then
      # normalise apt-get -> apt
      DEV_PKG="${c/apt-get/apt}"
      return
    fi
  done
}

_detect_misc() {
  DEV_HOSTNAME="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"
  DEV_USER="${USER:-$(id -un 2>/dev/null || echo unknown)}"

  # Root needs no sudo; otherwise use it if present.
  if [ "$(id -u)" -eq 0 ]; then
    DEV_SUDO=""
  elif command -v sudo >/dev/null 2>&1; then
    DEV_SUDO="sudo"
  else
    DEV_SUDO=""
  fi

  if [ "$DEV_OS" = macos ]; then
    DEV_HAS_GUI=true
  elif [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    DEV_HAS_GUI=true
  else
    DEV_HAS_GUI=false
  fi
}

detect_machine() {
  _detect_os
  _detect_arch
  _detect_distro
  _detect_virt
  _detect_pkg
  _detect_misc
}

# ---------------------------------------------------------------------------
# helpers for the install scripts
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# version_ge <have> <want> - true when <have> is at least <want>.
# sort -V does the comparing, so 2.34.1 vs 2.9 orders correctly (unlike a
# plain string or float compare, which would call 2.9 the newer one).
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# version_of <cmd> [args...] - first dotted number from the tool's --version.
version_of() {
  "$@" --version 2>/dev/null | head -n1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1
}

require_linux() {
  [ "$DEV_OS" = linux ] || { echo "This script needs Linux (found: $DEV_OS)" >&2; return 1; }
}

require_macos() {
  [ "$DEV_OS" = macos ] || { echo "This script needs macOS (found: $DEV_OS)" >&2; return 1; }
}

_DEV_PKG_REFRESHED=false

# Refresh package metadata, at most once per shell.
pkg_refresh() {
  [ "$_DEV_PKG_REFRESHED" = true ] && return 0
  case "$DEV_PKG" in
    apt)    $DEV_SUDO apt-get update ;;
    dnf)    $DEV_SUDO dnf check-update || true ;;   # exits 100 when updates exist
    yum)    $DEV_SUDO yum check-update || true ;;
    pacman) $DEV_SUDO pacman -Sy ;;
    zypper) $DEV_SUDO zypper refresh ;;
    apk)    $DEV_SUDO apk update ;;
    brew)   brew update ;;                          # never sudo for brew
    none)   echo "No package manager detected" >&2; return 1 ;;
  esac
  _DEV_PKG_REFRESHED=true
}

# pkg_install <pkg>...
pkg_install() {
  [ $# -gt 0 ] || return 0
  case "$DEV_PKG" in
    apt)    pkg_refresh && $DEV_SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)    $DEV_SUDO dnf install -y "$@" ;;
    yum)    $DEV_SUDO yum install -y "$@" ;;
    pacman) $DEV_SUDO pacman -S --noconfirm --needed "$@" ;;
    zypper) $DEV_SUDO zypper install -y "$@" ;;
    apk)    $DEV_SUDO apk add "$@" ;;
    brew)   brew install "$@" ;;                    # never sudo for brew
    none)   echo "No package manager detected; cannot install: $*" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# reporting (only when run directly)
# ---------------------------------------------------------------------------

_report_text() {
  local kind="bare metal"
  [ "$DEV_IS_VM" = true ] && kind="virtual machine ($DEV_VIRT)"
  [ "$DEV_IS_CONTAINER" = true ] && kind="container ($DEV_VIRT)"
  [ "$DEV_IS_WSL" = true ] && kind="WSL"

  printf '%-16s %s\n' \
    "OS:"        "$DEV_OS" \
    "Distro:"    "${DEV_PRETTY_NAME:-$DEV_DISTRO}" \
    "Family:"    "${DEV_DISTRO_LIKE:-–}" \
    "Codename:"  "${DEV_CODENAME:-–}" \
    "Arch:"      "$DEV_ARCH" \
    "Kernel:"    "$DEV_KERNEL" \
    "Machine:"   "$kind" \
    "Packages:"  "$DEV_PKG" \
    "GUI:"       "$DEV_HAS_GUI" \
    "Root via:"  "${DEV_SUDO:-already root}" \
    "Host:"      "$DEV_HOSTNAME" \
    "User:"      "$DEV_USER"
}

_report_json() {
  cat <<EOF
{
  "os": "$DEV_OS",
  "distro": "$DEV_DISTRO",
  "distro_like": "$DEV_DISTRO_LIKE",
  "version_id": "$DEV_VERSION_ID",
  "codename": "$DEV_CODENAME",
  "pretty_name": "$DEV_PRETTY_NAME",
  "arch": "$DEV_ARCH",
  "kernel": "$DEV_KERNEL",
  "pkg": "$DEV_PKG",
  "virt": "$DEV_VIRT",
  "is_vm": $DEV_IS_VM,
  "is_container": $DEV_IS_CONTAINER,
  "is_wsl": $DEV_IS_WSL,
  "has_gui": $DEV_HAS_GUI,
  "sudo": "$DEV_SUDO",
  "hostname": "$DEV_HOSTNAME",
  "user": "$DEV_USER"
}
EOF
}

# Executed directly? Then be strict and print a report. Sourced? Stay quiet.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  detect_machine
  case "${1:-}" in
    --json) _report_json ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
      ;;
    "")     _report_text ;;
    *)      echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
else
  detect_machine
fi
