#!/usr/bin/env bash
# cloudflared — Cloudflare Tunnel SSH client access to ssh.babanin.de.
#
# This module is OPT-IN (run via `bootstrap.sh --with-cloudflared`, `--all`, or
# `devenv install cloudflared`). It regenerates the three things that do NOT
# survive a VM rebuild:
#   1. the cloudflared binary (arch-specific .deb),
#   2. a durable DNS config (systemd-resolved drop-in), and
#   3. the ~/.ssh/config ProxyCommand stanza.
#
# The SSH private key / known_hosts are NOT handled here — they are persisted by
# the existing `.ssh` ARCHIVE_DIR (see bin/lib.sh) and restored before this runs.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../bin/lib.sh"

SSH_HOST="ssh.babanin.de"
SSH_CONFIG="$HOME/.ssh/config"

# ---- 1. install cloudflared ---------------------------------------------
if have cloudflared; then
    ok "cloudflared: already installed ($(cloudflared --version 2>&1 | head -1))"
else
    arch="$(dpkg --print-architecture)"
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
    log "cloudflared: downloading $url"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    if curl -fsSL "$url" -o "$tmp/cloudflared.deb"; then
        maybe_sudo dpkg -i "$tmp/cloudflared.deb"
        rm -rf "$tmp"; trap - EXIT
        if have cloudflared; then
            ok "cloudflared: installed ($(cloudflared --version 2>&1 | head -1))"
        else
            die "cloudflared: dpkg ran but binary not on PATH"
        fi
    else
        rm -rf "$tmp"; trap - EXIT
        die "cloudflared: download failed (offline?): $url"
    fi
fi

# ---- 2. DNS hardening (guarded) -----------------------------------------
# cloudflared access ssh silently fails if DNS can't resolve. The cloud default
# resolver (169.254.169.254) is unreachable here; a systemd-resolved drop-in is
# the durable fix that cloud-init won't clobber on reboot. Act only when
# systemd-resolved is the resolver AND the drop-in is missing (idempotent).
dropin="/etc/systemd/resolved.conf.d/dns.conf"
if have systemctl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    if [ -f "$dropin" ]; then
        ok "cloudflared-dns: drop-in already present ($dropin)"
    else
        log "cloudflared-dns: writing $dropin"
        maybe_sudo mkdir -p /etc/systemd/resolved.conf.d
        printf '[Resolve]\nDNS=1.1.1.1 1.0.0.1\nFallbackDNS=8.8.8.8\n' \
            | maybe_sudo tee "$dropin" >/dev/null
        maybe_sudo systemctl restart systemd-resolved
        ok "cloudflared-dns: drop-in installed and systemd-resolved restarted"
    fi

    # The drop-in above only helps tools that route DNS through systemd-resolved.
    # cloudflared is a Go binary: it reads /etc/resolv.conf DIRECTLY and does not
    # use nsswitch's `resolve` module. The cloud image leaves a "foreign"
    # /etc/resolv.conf pointing only at the GCE metadata resolver
    # (169.254.169.254), which is UNREACHABLE in this emulator. Result:
    # `getent hosts ssh.babanin.de` succeeds (via systemd-resolved) so doctor
    # used to report "all clear", yet `cloudflared access ssh` hangs on DNS and
    # ssh times out. Point /etc/resolv.conf at the systemd-resolved stub so the
    # resolv.conf path and the nsswitch path agree.
    stub="/run/systemd/resolve/stub-resolv.conf"
    if [ -e "$stub" ]; then
        if [ "$(readlink -f /etc/resolv.conf 2>/dev/null)" = "$(readlink -f "$stub" 2>/dev/null)" ]; then
            ok "cloudflared-dns: /etc/resolv.conf already -> systemd-resolved stub"
        else
            log "cloudflared-dns: repointing /etc/resolv.conf at the stub (was: $(grep -m1 '^[[:space:]]*nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' || echo none))"
            maybe_sudo ln -sf "$stub" /etc/resolv.conf
            ok "cloudflared-dns: /etc/resolv.conf -> $stub"
        fi
    else
        warn "cloudflared-dns: stub $stub missing; cannot repair resolv.conf (cloudflared may hang on DNS)"
    fi
else
    warn "cloudflared-dns: systemd-resolved not active; leaving DNS untouched"
fi

# ---- 3. SSH config ProxyCommand stanza ----------------------------------
# Safety-net: guarantee the ProxyCommand entry even if ~/.ssh/config were ever
# lost while the key survived. Append-only if no matching Host line exists; never
# duplicates, never edits an existing stanza. Non-secret, safe to regenerate.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ -f "$SSH_CONFIG" ] && grep -qE "^[[:space:]]*Host[[:space:]]+${SSH_HOST}([[:space:]]|\$)" "$SSH_CONFIG"; then
    ok "cloudflared-ssh: ~/.ssh/config already has Host $SSH_HOST"
else
    log "cloudflared-ssh: appending Host $SSH_HOST stanza to ~/.ssh/config"
    # Leading newline guards against a config file with no trailing newline.
    cat >> "$SSH_CONFIG" <<EOF

Host ${SSH_HOST}
    ProxyCommand cloudflared access ssh --hostname %h
    User db
    IdentityFile ~/.ssh/id_ed25519
    # Phone notifications from PC-side Claude Code: tunnel 9876 back to the
    # guest's claude-notify-listen, started lazily on first connect.
    RemoteForward 127.0.0.1:9876 127.0.0.1:9876
    PermitLocalCommand yes
    LocalCommand /usr/local/bin/claude-notify-listen --ensure
EOF
    ok "cloudflared-ssh: appended Host $SSH_HOST stanza"
fi
chmod 600 "$SSH_CONFIG"

ok "cloudflared: done"
