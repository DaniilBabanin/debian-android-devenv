#!/usr/bin/env bash
# Claude Code — native installer (not npm).
# ~/.claude is managed by `devenv snapshot` / `devenv restore` (NOT symlinked into
# /mnt/shared, because virtio-fs corrupts SQLite). On a rebuild, bootstrap.sh runs
# restore before this module, so creds and history are already in place.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../bin/lib.sh"

# ---- Notification hook: phone notification when Claude waits for input ------
# Runs BEFORE the already-installed early-exit so re-runs keep it registered
# (settings.json is NOT in SNAPSHOT_FILES — wiped on rebuild, recreated here).
# Script no-ops where Termux:API is absent (VM/PC), so registering is safe
# everywhere.
log "claude: install claude-notify hook"
install -m 0755 "$DEVENV_BIN/claude-notify" /usr/local/bin/claude-notify
# Listener for PC-side Claude notifications arriving over the ssh
# RemoteForward (see bin/claude-notify-listen); started lazily by ssh
# LocalCommand (install-cloudflared.sh stanza). No-op where socat is absent.
install -m 0755 "$DEVENV_BIN/claude-notify-listen" /usr/local/bin/claude-notify-listen
settings="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -s "$settings" ] || printf '{}\n' > "$settings"
if have jq; then
    if jq -e '.hooks.Notification[]?.hooks[]? | select(.command == "/usr/local/bin/claude-notify")' \
            "$settings" >/dev/null 2>&1; then
        ok "claude: Notification hook already registered"
    else
        tmp="$(mktemp)"
        jq '.hooks.Notification = ((.hooks.Notification // []) +
              [{"hooks": [{"type": "command", "command": "/usr/local/bin/claude-notify"}]}])' \
            "$settings" > "$tmp" && mv "$tmp" "$settings"
        ok "claude: registered Notification hook in ~/.claude/settings.json"
    fi
else
    warn "claude: jq missing — Notification hook NOT registered (run 'devenv install base' then re-run)"
fi

if have claude; then
    exit 0
    ok "claude: already installed: $(claude --version 2>&1 | head -1)"
    log "claude: re-running installer to upgrade (skip with: SKIP_UPGRADE=1)"
    [ "${SKIP_UPGRADE:-0}" = "1" ] && exit 0
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
