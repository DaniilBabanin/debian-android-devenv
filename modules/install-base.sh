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
    shellcheck
    yq
    sqlite3
    gitleaks
    dasel
    strace
    hyperfine
    expect
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

# difftastic: not packaged for Debian; fetch the prebuilt arm64/x86_64 binary.
if ! have difft; then
    case "$(dpkg --print-architecture)" in
        arm64) DIFFT_TARGET="aarch64-unknown-linux-gnu" ;;
        amd64) DIFFT_TARGET="x86_64-unknown-linux-gnu" ;;
        *)     DIFFT_TARGET="" ;;
    esac
    if [ -n "$DIFFT_TARGET" ] && have curl && have jq && have tar; then
        log "base: fetching difftastic ($DIFFT_TARGET)"
        difft_url=$(curl -fsSL https://api.github.com/repos/Wilfred/difftastic/releases/latest \
            | jq -r --arg t "$DIFFT_TARGET" '.assets[] | select(.name | endswith($t + ".tar.gz")) | .browser_download_url')
        if [ -n "$difft_url" ]; then
            tmp=$(mktemp -d)
            trap 'rm -rf "$tmp"' EXIT
            curl -fsSL "$difft_url" -o "$tmp/difft.tar.gz"
            tar -xzf "$tmp/difft.tar.gz" -C "$tmp"
            install -m 0755 "$tmp/difft" "$HOME/.local/bin/difft"
            trap - EXIT; rm -rf "$tmp"
            ok "installed difft -> ~/.local/bin/difft"
        else
            warn "could not resolve difftastic release URL — skipping"
        fi
    else
        warn "skipping difftastic install (unsupported arch or missing curl/jq/tar)"
    fi
fi

ok "base: done"
