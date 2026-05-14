#!/usr/bin/env bash
# Claude Code — native installer (not npm).
# ~/.claude is managed by `devenv snapshot` / `devenv restore` (NOT symlinked into
# /mnt/shared, because virtio-fs corrupts SQLite). On a rebuild, bootstrap.sh runs
# restore before this module, so creds and history are already in place.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../bin/lib.sh"

if have claude; then
    ok "claude: already installed: $(claude --version 2>&1 | head -1)"
    exit 0
fi

have curl || die "claude: need curl (run 'devenv install base' first)"

log "claude: running native installer"
curl -fsSL https://claude.ai/install.sh | bash

# Native installer typically drops claude into ~/.local/bin or similar — make sure it's reachable.
if ! have claude; then
    for cand in "$HOME/.local/bin/claude" "$HOME/.claude/bin/claude" "/usr/local/bin/claude"; do
        [ -x "$cand" ] && { warn "claude: $cand exists but not on PATH yet; open a new shell"; break; }
    done
fi

if have claude; then
    ok "claude: $(claude --version 2>&1 | head -1)"
else
    warn "claude: installer ran but binary not yet on PATH — start a new shell and re-check"
fi
