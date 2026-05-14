#!/usr/bin/env bash
# Node via nvm. ~/.nvm itself is NOT persisted — it's reinstalled per Debian rootfs.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../bin/lib.sh"

NVM_VERSION="v0.40.1"   # pin a known-good tag; bump as desired
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    log "node: installing nvm $NVM_VERSION"
    have curl || die "node: need curl (run 'devenv install base' first)"
    PROFILE=/dev/null bash -c \
        "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash"
else
    ok "node: nvm already present at $NVM_DIR"
fi

# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"

if ! nvm ls --no-colors 2>/dev/null | grep -q 'lts/'; then
    log "node: installing latest LTS"
    nvm install --lts
    nvm alias default 'lts/*'
else
    ok "node: LTS already installed ($(nvm current))"
fi

ok "node: $(node --version) / npm $(npm --version)"
