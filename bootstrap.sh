#!/usr/bin/env bash
# bootstrap.sh — one-command VM rebuild for Debian-on-Android.
#
# Default flow (idempotent, safe to re-run any time):
#   1. init        link read-mostly dotfiles into $HOME, install the snapshot
#                  systemd --user unit, put `devenv` on PATH
#   2. restore     copy ~/.claude, ~/.config, ~/.bash_history back from the
#                  on-disk snapshot at $DEVENV_ROOT/state (skipped if none yet)
#   3. install     run the essential modules: base + claude + cloudflared
#                  add --with-node and/or --with-python to opt in to those
#   4. snapshot    refresh $DEVENV_ROOT/state from the live $HOME so the next
#                  rebuild has fresh state (skip with --no-snapshot)
#   5. probe       append a degradation-signal baseline for this boot to
#                  metrics/probe.jsonl (best-effort; see docs/harden-spec.md)
#
# Usage:
#   bash /mnt/shared/debian-env/bootstrap.sh                # essentials + snapshot
#   bash /mnt/shared/debian-env/bootstrap.sh --with-node    # + node toolchain
#   bash /mnt/shared/debian-env/bootstrap.sh --with-python  # + python toolchain
#   bash /mnt/shared/debian-env/bootstrap.sh --with-cloudflared # no-op (cloudflared now default)
#   bash /mnt/shared/debian-env/bootstrap.sh --all          # every module
#   bash /mnt/shared/debian-env/bootstrap.sh --init-only    # only step 1
#   bash /mnt/shared/debian-env/bootstrap.sh --no-snapshot  # skip step 4
#   bash /mnt/shared/debian-env/bootstrap.sh --rollback     # restore previous snapshot version
#   bash /mnt/shared/debian-env/bootstrap.sh --rollback=2   # restore 2 versions back
#   bash /mnt/shared/debian-env/bootstrap.sh base claude    # explicit module list
#                                                           # (still runs init,
#                                                           #  restore, snapshot)

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/bin/lib.sh"

usage() {
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^#\s\{0,1\}//'
}

# ---- flag parsing --------------------------------------------------------

mode="default"           # default | all | init-only | explicit
with_node=0
with_python=0
do_snapshot=1
explicit_modules=()
restore_args=()

while [ $# -gt 0 ]; do
    case "$1" in
        --init-only)    mode="init-only" ;;
        --all)          mode="all" ;;
        --with-node)    with_node=1 ;;
        --with-python)  with_python=1 ;;
        --with-cloudflared) : ;;  # no-op: cloudflared is now in the default set
        --no-snapshot)  do_snapshot=0 ;;
        --rollback)     restore_args+=(--rollback) ;;
        --rollback=*)   restore_args+=("$1") ;;
        -h|--help)      usage; exit 0 ;;
        --*)            err "unknown flag: $1"; usage; exit 2 ;;
        *)              explicit_modules+=("$1"); mode="explicit" ;;
    esac
    shift
done

step "bootstrap: $DEVENV_ROOT  (mode=$mode)"

# Writability sanity — if the shared mount is read-only here, snapshot will
# fail later, and we'd rather know now.
[ -w "$DEVENV_ROOT" ] || warn "$DEVENV_ROOT is not writable — sentinels and snapshots will fail"

# ---- step 1: init --------------------------------------------------------

bash "$DEVENV_BIN/init.sh"

# Refresh PATH for this shell so devenv (just linked) is callable.
export PATH="$HOME/.local/bin:$PATH"

if [ "$mode" = "init-only" ]; then
    ok "bootstrap: init-only complete"
    exit 0
fi

# ---- ensure rsync before any copying -------------------------------------
# devenv snapshot/restore copy through /mnt/shared (virtio-fs / sdcardfs).
# `cp -a` on that mount can crash the VM, so rsync is mandatory — install it
# before step 2 even though install-base would otherwise pull it in later.
if ! have rsync; then
    log "installing rsync (required for restore/snapshot on shared mount)"
    maybe_sudo apt-get update
    maybe_sudo apt-get install -y --no-install-recommends rsync
fi

# ---- step 2: restore -----------------------------------------------------

# Restore if either an rsync snapshot, any tar archive, OR any per-file
# snapshot exists. Archives (e.g. ~/.ssh) and SNAPSHOT_FILES entries
# (e.g. ~/.claude/CLAUDE.md) may be present on a first run where snapshot.ts
# isn't, and SNAPSHOT_FILES also has template-seed fallback under
# $DEVENV_HOME so a clean install still gets a starter CLAUDE.md.
has_state=0
[ -f "$DEVENV_SNAPSHOT_DIR/snapshot.ts" ] && has_state=1
for __arch in "$DEVENV_ARCHIVES"/*.tar.gz; do
    [ -f "$__arch" ] && { has_state=1; break; }
done
unset __arch
if [ "$has_state" = 0 ] && [ -d "$DEVENV_SNAPSHOT_DIR/files" ]; then
    has_state=1
fi
if [ "$has_state" = 0 ]; then
    for __rel in "${SNAPSHOT_FILES[@]}"; do
        [ -f "$DEVENV_HOME/$__rel" ] && { has_state=1; break; }
    done
    unset __rel
fi
if [ "$has_state" = 1 ]; then
    devenv restore "${restore_args[@]}"
else
    log "no snapshot or archive at $DEVENV_ROOT — skipping restore (first-run case)"
fi

# ---- step 3: install -----------------------------------------------------

case "$mode" in
    explicit)
        log "installing explicit modules: ${explicit_modules[*]}"
        devenv install "${explicit_modules[@]}"
        ;;
    all)
        devenv install all
        ;;
    default)
        # cloudflared is in the default set (SSH access to ssh.babanin.de).
        # --with-cloudflared is now a no-op kept for back-compat.
        mods=(base claude cloudflared)
        [ "$with_node"   = 1 ] && mods+=(node)
        [ "$with_python" = 1 ] && mods+=(python)
        # claude-plugins must come after claude (uses the CLI it installs).
        mods+=(claude-plugins)
        # watch: degradation episode logger (systemd --user). Needs jq (base)
        # and the devenv symlink (init) — both present by now.
        mods+=(watch)
        devenv install "${mods[@]}"
        ;;
esac

# ---- step 4: snapshot ----------------------------------------------------

if [ "$do_snapshot" = 1 ]; then
    devenv snapshot
else
    log "snapshot skipped (--no-snapshot)"
fi

# ---- step 5: probe baseline ----------------------------------------------
# Append a degradation-signal sample tagged with this boot so metrics/probe.jsonl
# accumulates a cross-rebuild trend automatically (see docs/harden-spec.md).
# Read-only + append; best-effort, never fails the bootstrap.
devenv probe --label boot-baseline >/dev/null 2>&1 || warn "probe baseline skipped"

ok "bootstrap: done. Open a new shell or run: source ~/.bashrc"
log "next VM rebuild: re-run \`bash $DEVENV_ROOT/bootstrap.sh\`"
