#!/usr/bin/env bash
# Base apt essentials.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../bin/lib.sh"

PKGS=(
    build-essential
    git
    curl
    wget
    ca-certificates
    gnupg
    unzip
    zip
    jq
    fzf
    ripgrep
    bat
    fd-find
    universal-ctags
    tokei
    gh
    htop
    less
    man-db
    file
    tree
    rsync
    tmux
    openssh-client
)

# Skip-fast if all already installed.
missing=()
for p in "${PKGS[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then missing+=("$p"); fi
done

if [ ${#missing[@]} -eq 0 ]; then
    ok "base: all packages already installed"
    exit 0
fi

log "base: installing ${#missing[@]} package(s): ${missing[*]}"
maybe_sudo apt-get update
maybe_sudo apt-get install -y --no-install-recommends "${missing[@]}"

# On Debian, ripgrep installs as `rg`, bat as `batcat`, fd as `fdfind`. Symlink
# the friendly names for convenience.
mkdir -p "$HOME/.local/bin"
if have batcat && ! have bat; then
    ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
    ok "linked bat -> batcat"
fi
if have fdfind && ! have fd; then
    ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
    ok "linked fd -> fdfind"
fi

ok "base: done"
