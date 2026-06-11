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
    socat
)

# Skip the apt work if all already installed. No early exit: the steps below
# (symlinks, difftastic, apt-automation masking) must still converge on a
# re-run — e.g. when a first run died after apt but before difftastic.
missing=()
for p in "${PKGS[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then missing+=("$p"); fi
done

if [ ${#missing[@]} -eq 0 ]; then
    ok "base: all packages already installed"
else
    log "base: installing ${#missing[@]} package(s): ${missing[*]}"
    maybe_sudo apt-get update
    maybe_sudo apt-get install -y --no-install-recommends "${missing[@]}"
fi

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
# Use the API-less `releases/latest/download/<asset>` redirect (the API call
# this used to make gets 403-rate-limited on shared IPs, e.g. mobile CGNAT).
# Best-effort: a download failure must never fail the module.
if ! have difft; then
    case "$(dpkg --print-architecture)" in
        arm64) DIFFT_TARGET="aarch64-unknown-linux-gnu" ;;
        amd64) DIFFT_TARGET="x86_64-unknown-linux-gnu" ;;
        *)     DIFFT_TARGET="" ;;
    esac
    if [ -n "$DIFFT_TARGET" ] && have curl && have tar; then
        log "base: fetching difftastic ($DIFFT_TARGET)"
        difft_url="https://github.com/Wilfred/difftastic/releases/latest/download/difft-${DIFFT_TARGET}.tar.gz"
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        if curl -fsSL "$difft_url" -o "$tmp/difft.tar.gz" \
            && tar -xzf "$tmp/difft.tar.gz" -C "$tmp" \
            && install -m 0755 "$tmp/difft" "$HOME/.local/bin/difft"; then
            ok "installed difft -> ~/.local/bin/difft"
        else
            warn "difftastic download/extract failed ($difft_url) — skipping (re-run 'devenv install base' to retry)"
        fi
        trap - EXIT; rm -rf "$tmp"
    else
        warn "skipping difftastic install (unsupported arch or missing curl/tar)"
    fi
fi

# Disable automatic apt activity. This VM is rebuilt often and reinstalls
# everything from dpkg-selections.txt + manifests, so unattended upgrades buy
# nothing — and a background apt run can grab the dpkg lock mid-session
# (blocking `devenv install`), change toolchain versions nondeterministically,
# or stall shutdown via unattended-upgrade-shutdown. Mask the lot. Idempotent:
# `systemctl mask` on an already-masked unit is a no-op.
step "disable automatic apt upgrades"
mask_units=(
    unattended-upgrades.service
    apt-daily.timer
    apt-daily-upgrade.timer
)
for u in "${mask_units[@]}"; do
    if maybe_sudo systemctl mask "$u" >/dev/null 2>&1; then
        ok "masked $u"
    else
        warn "could not mask $u (may not exist on this image)"
    fi
done

ok "base: done"
