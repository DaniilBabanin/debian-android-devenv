#!/usr/bin/env bash
# termux/bootstrap.sh — Termux-side bootstrap: proot-distro Debian + devenv inside.
#
# The AVF Debian VM (com.android.virtualization.terminal) proved unstable, so
# this shim runs the SAME devenv unchanged inside proot-distro Debian on Termux:
#
#   Termux (bionic)   wake-lock, tmux server, proot lifecycle      (this script)
#   proot Debian      apt modules, dotfiles, Claude Code           (../bootstrap.sh)
#   repo on /sdcard   bound to /mnt/shared inside proot, so every
#                     path matches the VM exactly
#
# Run from Termux (after `termux-setup-storage`):
#   bash ~/storage/shared/Sync/debian-env/termux/bootstrap.sh
#
# Idempotent — safe to re-run any time. Next steps after it finishes:
#   bash ~/storage/shared/Sync/debian-env/termux/mitigate.sh   # phantom-killer, once
#   dev                                                        # enter the session

set -euo pipefail

# ---- output helpers (self-contained; bin/lib.sh stays proot-side) ----------
log()  { printf '\033[34m[termux]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
step() { printf '\n\033[34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

# ---- guards -----------------------------------------------------------------
case "${PREFIX:-}" in
    */com.termux/*) : ;;
    *) die "this script must run inside Termux (PREFIX=${PREFIX:-unset})" ;;
esac

# Resolve the repo root from this script's location, through the ~/storage
# symlinks, to the Android-absolute path (/storage/emulated/0/...).
self="$(readlink -f "${BASH_SOURCE[0]}")"
TERMUX_REPO="$(cd "$(dirname "$self")/.." && pwd)"

# Inside proot we bind /storage/emulated/0 -> /mnt/shared, so the repo path in
# the guest is identical to what the VM used (/mnt/shared/Sync/debian-env).
ANDROID_STORAGE="/storage/emulated/0"
case "$TERMUX_REPO" in
    "$ANDROID_STORAGE"/*) PROOT_REPO="/mnt/shared/${TERMUX_REPO#"$ANDROID_STORAGE"/}" ;;
    *) die "repo at $TERMUX_REPO is not under $ANDROID_STORAGE — move it to shared storage (e.g. /sdcard/Sync/debian-env)" ;;
esac

step "termux bootstrap: $TERMUX_REPO  (guest: $PROOT_REPO)"

if [ ! -e "$HOME/storage/shared" ]; then
    warn "shared storage not linked yet — requesting permission"
    termux-setup-storage
    die "grant the storage permission, then re-run this script"
fi
[ -w "$TERMUX_REPO" ] || warn "$TERMUX_REPO not writable — sentinels/metrics writes will fail"

# ---- step 1: Termux packages -------------------------------------------------
step "termux packages"
needed=()
have proot-distro      || needed+=(proot-distro)
have tmux              || needed+=(tmux)
# NOT termux-wake-lock: that ships in termux-tools (preinstalled), so probing
# it never pulled termux-api. termux-notification genuinely comes from termux-api.
have termux-notification || needed+=(termux-api)
have adb               || needed+=(android-tools)   # for mitigate.sh
if [ ${#needed[@]} -gt 0 ]; then
    log "installing: ${needed[*]}"
    pkg install -y "${needed[@]}"
else
    ok "all present (proot-distro tmux termux-api android-tools)"
fi

# ---- step 2: Debian rootfs ----------------------------------------------------
# Probe by logging in rather than checking rootfs paths — proot-distro's
# on-disk layout changed across versions (OCI containers vs installed-rootfs).
step "proot-distro debian rootfs"
if proot-distro login debian -- true >/dev/null 2>&1; then
    ok "debian container present"
else
    proot-distro install debian
fi

# Bind target must exist in the guest before --bind can shadow it reliably.
proot-distro login debian -- mkdir -p /mnt/shared

# All guest logins use the same bind so paths match the VM. Keep in sync with
# termux/bin/dev.
PD_BIND=(--bind "$ANDROID_STORAGE:/mnt/shared")

# ---- step 2.5: pre-restore snapshot on re-runs ----------------------------------
# The inner bootstrap restores BEFORE it snapshots. On a re-run over a live
# guest that order would clobber newer state (rotated Claude creds, fresh
# ~/.ssh) with an older snapshot — so capture the live state first. First run
# (no devenv in the guest yet) skips silently.
step "pre-restore snapshot (re-run protection)"
if proot-distro login debian "${PD_BIND[@]}" -- bash -lc 'devenv snapshot' >/dev/null 2>&1; then
    ok "live guest state snapshotted before restore"
else
    log "guest has no working devenv yet — first run, nothing to protect"
fi

# ---- step 3: devenv inside the guest ------------------------------------------
# Explicit module list (not default mode): skips `watch` (systemd-only).
# Termux is the primary runtime now (2026-06): the guest both consumes and
# PRODUCES snapshots — bootstrap refreshes one at the end, and `dev` keeps the
# window fresh via a staleness check (DEV_SNAPSHOT_MAX_AGE_DAYS, default 3).
# The old --no-snapshot "VM-pure window" policy is retired with the VM.
#
# Exec-bit hedge: the inner bootstrap calls `devenv` via the ~/.local/bin
# symlink that init.sh creates, whose target sits on /sdcard (FUSE: no exec
# bit). proot's fake-root mode normally papers over that; in case it doesn't,
# a fallback `devenv` wrapper is appended to PATH — bash skips non-executable
# PATH candidates and falls through to it.
step "devenv bootstrap inside proot (this is the long step)"
proot-distro login debian "${PD_BIND[@]}" -- bash -c "
    set -euo pipefail
    mkdir -p /opt/devenv-shim
    printf '#!/bin/bash\nexec bash %q/bin/devenv \"\$@\"\n' '$PROOT_REPO' > /opt/devenv-shim/devenv
    chmod +x /opt/devenv-shim/devenv
    export PATH=\"\$PATH:/opt/devenv-shim\"
    bash '$PROOT_REPO/bootstrap.sh' base claude cloudflared claude-plugins
"

# ---- step 4: make `devenv` durable for interactive shells ----------------------
# Interactive shells don't have the shim dir on PATH, so replace the symlink
# with the wrapper outright — it works whether or not symlink-exec does.
# (A later bare `devenv init` inside the guest re-creates the symlink; if that
# breaks `devenv` on this device, re-running this script re-fixes it.)
step "verify devenv dispatcher"
proot-distro login debian "${PD_BIND[@]}" -- bash -c "
    set -eu
    mkdir -p \"\$HOME/.local/bin\"
    rm -f \"\$HOME/.local/bin/devenv\"
    cp /opt/devenv-shim/devenv \"\$HOME/.local/bin/devenv\"
    chmod +x \"\$HOME/.local/bin/devenv\"
"
if proot-distro login debian "${PD_BIND[@]}" -- bash -lc 'devenv list' >/dev/null 2>&1; then
    ok "devenv dispatcher works in a login shell"
else
    warn "devenv not resolving in a login shell — run 'dev' and debug interactively"
fi

# ---- step 5: KEYBOARD extra key ---------------------------------------------------
# `dev` turns tmux mouse mode on so taps focus panes — which means Termux no
# longer gets a plain tap to reopen the soft keyboard (same with Claude Code's
# own mouse tracking, even without tmux mouse). The KEYBOARD extra key (and
# the left-edge-drawer KEYBOARD button) bring it back.
step "termux.properties: KEYBOARD extra key"
props="$HOME/.termux/termux.properties"
mkdir -p "$HOME/.termux"
if grep -q '^extra-keys' "$props" 2>/dev/null; then
    ok "extra-keys already configured (left as-is)"
else
    {
        printf '\n# devenv termux/bootstrap.sh: row + PGUP/PGDN + KEYBOARD (reopens soft keyboard;\n'
        printf '# taps go to tmux mouse mode, so tapping the terminal no longer opens it)\n'
        printf 'extra-keys = [[ESC, TAB, CTRL, ALT, SHIFT, DOWN, UP, PGUP, PGDN, KEYBOARD]]\n'
    } >> "$props"
    termux-reload-settings 2>/dev/null || true
    ok "added KEYBOARD to the extra-keys row"
fi

# ---- step 6: install the `dev` entry command -----------------------------------
# Copy, not symlink: /sdcard has no exec bit, $PREFIX/bin does. Re-copied on
# every run, so editing termux/bin/dev in the repo + re-running updates it.
step "install dev wrapper"
install -m 0755 "$TERMUX_REPO/termux/bin/dev" "$PREFIX/bin/dev"
ok "installed $PREFIX/bin/dev"

# ---- step 7: Termux:Widget shortcuts --------------------------------------------
# One-tap launchers. Needs the Termux:Widget app (same source as Termux —
# GitHub/F-Droid, never mixed). Two consumers, two dirs:
#   ~/.shortcuts                            home-screen widget (auto-detects)
#   ~/.termux/widget/dynamic_shortcuts      launcher long-press/search — needs
#                                           a ONE-TIME tap on "CREATE SHORTCUTS"
#                                           inside the Termux:Widget app
# Same copy-not-symlink rationale as `dev`; re-copied every run.
step "install Termux:Widget shortcuts"
for widget_dir in "$HOME/.shortcuts" "$HOME/.termux/widget/dynamic_shortcuts"; do
    mkdir -p "$widget_dir"
    for s in "$TERMUX_REPO"/termux/widget/*; do
        install -m 0755 "$s" "$widget_dir/$(basename "$s")"
    done
    ok "installed shortcuts -> $widget_dir"
done

# ---- done ----------------------------------------------------------------------
step "bootstrap done"
cat <<EOF
next steps:
  1. one-time (if not done): disable the Android phantom-process killer —
         bash $TERMUX_REPO/termux/mitigate.sh
     and walk the Samsung checklist it prints. Skipping this = random
     signal-9 kills under multi-process load (exactly what Claude Code does).
  2. enter the environment:
         dev
     (wake-lock + tmux session 'dev' + proot Debian login; detach: Ctrl-b d)
  3. inside, same as the VM: claudea  /  devenv doctor  /  devenv list
  4. Termux-side health + disaster recovery: dev doctor / dev backup
EOF
