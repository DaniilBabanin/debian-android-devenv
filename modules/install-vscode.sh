#!/usr/bin/env bash
# vscode — VS Code in the phone browser, for local AND remote (PC) files.
#
# This module is OPT-IN (run via `devenv install vscode` or bootstrap with an
# explicit module list). Two pieces, both reached from the phone browser:
#
#   local files   code-server in this proot Debian  -> http://localhost:8080
#   PC files      `code serve-web` on the PC (:8000), reached through an
#                 autossh LocalForward inside the cloudflared ssh tunnel
#                                                    -> http://localhost:8001
#
# Local forward port is 8001, NOT 8000: some Android app squats the phone's
# 8000 (bind fails, ExitOnForwardFailure kills the session).
#
# Deliberately NOT Microsoft Remote Tunnels: those relay through MS dev-tunnel
# servers. This path is ssh end-to-end (Cloudflare only sees ssh ciphertext).
#
# What does NOT survive a rebuild (this module regenerates):
#   - code-server install (/usr/lib/code-server) + autossh (apt)
#   - /usr/local/bin/{code-local,pc-tunnel,pc-setup-code-web}
#   - the `Host pc` stanza in ~/.ssh/config IF ~/.ssh archive was lost
# What survives elsewhere: ~/.config/code-server/config.yaml (STATEFUL_DIRS
# .config — keeps the password stable), ~/.ssh (ARCHIVE_DIRS).
#
# PC side is one-time per PC (systemd user service `code-web`, survives on its
# own): run `pc-setup-code-web pc` once after this module. Snap gotcha handled
# there: /snap/bin/code shim injects --ozone-platform which breaks `serve-web`
# under systemd, so the service must exec .../usr/share/code/bin/code-tunnel.
#
# Daily use (inside the dev session):
#   tmux new -d -s code-local code-local   # local editor
#   tmux new -d -s pc-tunnel  pc-tunnel    # forward to PC, auto-reconnect
# then browser -> localhost:8080 / localhost:8001, Add to Home screen (PWA).
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../bin/lib.sh"

SSH_CONFIG="$HOME/.ssh/config"
SSH_HOST="ssh.babanin.de"

# ---- 1. autossh -----------------------------------------------------------
if have autossh; then
    ok "vscode: autossh already installed"
else
    log "vscode: installing autossh"
    maybe_sudo apt-get install -y --no-install-recommends autossh
fi

# ---- 2. code-server (local editor) ----------------------------------------
if have code-server; then
    ok "vscode: code-server already installed ($(code-server --version 2>/dev/null | head -1))"
else
    log "vscode: installing code-server (official installer)"
    curl -fsSL https://code-server.dev/install.sh | sh
    have code-server || die "vscode: installer ran but code-server not on PATH"
fi
# Config (~/.config/code-server/config.yaml: localhost:8080 + password) is
# auto-generated on first run and persisted via the .config snapshot. Keep
# password auth ON — other Android apps can reach the phone's localhost.

# ---- 3. launcher scripts ---------------------------------------------------
# Overwritten on every run so editing this module + re-running updates them.
log "vscode: installing /usr/local/bin/{code-local,pc-tunnel,pc-setup-code-web}"

maybe_sudo tee /usr/local/bin/code-local >/dev/null <<'EOF'
#!/bin/bash
# Local code-server (this Debian proot) on http://localhost:8080
# Start inside tmux: tmux new -d -s code-local code-local
termux-wake-lock 2>/dev/null
exec code-server
EOF

maybe_sudo tee /usr/local/bin/pc-tunnel >/dev/null <<'EOF'
#!/bin/bash
# Keep ssh tunnel to PC alive (VS Code serve-web: phone :8001 -> PC :8000).
# Runs in foreground; start inside tmux: tmux new -d -s pc-tunnel pc-tunnel
set -u

termux-wake-lock 2>/dev/null

# autossh: -M 0 = rely on ServerAlive* in ~/.ssh/config for liveness
# AUTOSSH_GATETIME=0: treat early exits as normal, keep retrying (tunnel may be down)
export AUTOSSH_GATETIME=0
export AUTOSSH_POLL=30
exec autossh -M 0 -N "${1:-pc-fwd}"
EOF

# PC-side payload: run as `pc-setup-code-web <host>` from the phone; pipes
# itself over ssh. One-time per PC; idempotent there too.
maybe_sudo tee /usr/local/bin/pc-setup-code-web >/dev/null <<'EOF'
#!/bin/bash
# Set up VS Code serve-web as a systemd user service on a PC, over ssh.
# Usage: pc-setup-code-web [ssh-host]    (default: pc)
set -eu
host="${1:-pc}"
ssh "$host" bash -s <<'REMOTE'
set -eu
# Prefer the real CLI binary: the /snap/bin/code shim injects --ozone-platform
# which `serve-web` rejects, exiting 0 silently -> systemd restart loop.
# /snap/code/current/ survives snap refreshes.
CODE_BIN=""
for c in /snap/code/current/usr/share/code/bin/code-tunnel \
         /usr/share/code/bin/code-tunnel \
         "$(command -v code || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && { CODE_BIN="$c"; break; }
done
[ -n "$CODE_BIN" ] || { echo "ERROR: no code/code-tunnel binary found — install VS Code first" >&2; exit 1; }

mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/code-web.service <<UNIT
[Unit]
Description=VS Code serve-web (localhost:8000)

[Service]
ExecStart=$CODE_BIN serve-web --host 127.0.0.1 --port 8000 --without-connection-token --accept-server-license-terms
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now code-web
loginctl enable-linger "$USER"
sleep 3
systemctl --user --no-pager status code-web | head -4
curl -s -o /dev/null -w "serve-web on PC: HTTP %{http_code}\n" http://localhost:8000
REMOTE
EOF

maybe_sudo chmod +x /usr/local/bin/code-local /usr/local/bin/pc-tunnel /usr/local/bin/pc-setup-code-web
ok "vscode: launcher scripts installed"

# ---- 4. ssh config: `Host pc` + `Host pc-fwd` stanzas -----------------------
# Two aliases, both self-contained (separate from the cloudflared module's
# `Host ssh.babanin.de` stanza):
#   pc      interactive ssh — NO forwards, so it never collides with the
#           running tunnel (one listener per port; ExitOnForwardFailure would
#           kill the whole connection otherwise)
#   pc-fwd  tunnel-only — carries the LocalForward; used by pc-tunnel/autossh
# Append-only; never edits an existing stanza. ~/.ssh/config normally survives
# via the .ssh archive — this is the safety net.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ -f "$SSH_CONFIG" ] && grep -qE "^[[:space:]]*Host[[:space:]]+pc([[:space:]]|\$)" "$SSH_CONFIG"; then
    ok "vscode-ssh: ~/.ssh/config already has Host pc"
else
    log "vscode-ssh: appending Host pc stanza to ~/.ssh/config"
    cat >> "$SSH_CONFIG" <<EOF

Host pc
    HostName ${SSH_HOST}
    ProxyCommand cloudflared access ssh --hostname %h
    User db
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 15
    ServerAliveCountMax 3
EOF
    ok "vscode-ssh: appended Host pc stanza"
fi
if grep -qE "^[[:space:]]*Host[[:space:]]+pc-fwd([[:space:]]|\$)" "$SSH_CONFIG" 2>/dev/null; then
    ok "vscode-ssh: ~/.ssh/config already has Host pc-fwd"
else
    log "vscode-ssh: appending Host pc-fwd stanza to ~/.ssh/config"
    cat >> "$SSH_CONFIG" <<EOF

Host pc-fwd
    HostName ${SSH_HOST}
    ProxyCommand cloudflared access ssh --hostname %h
    User db
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 15
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
    LocalForward 8001 localhost:8000
    LocalForward 8080 localhost:8080
    LocalForward 8137 localhost:8137
EOF
    ok "vscode-ssh: appended Host pc-fwd stanza"
fi
chmod 600 "$SSH_CONFIG"

ok "vscode: done — start with: tmux new -d -s code-local code-local ; tmux new -d -s pc-tunnel pc-tunnel"
log "vscode: first time against a new PC: pc-setup-code-web pc"
