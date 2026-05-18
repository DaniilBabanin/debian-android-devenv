#!/usr/bin/env bash
# bootstrap.sh — one-command VM rebuild for Debian-on-Android.
#
# Default flow (idempotent, safe to re-run any time):
#   1. init        link read-mostly dotfiles into $HOME, install the snapshot
#                  systemd --user unit, put `devenv` on PATH
#   2. restore     copy ~/.claude, ~/.config, ~/.bash_history back from the
#                  on-disk snapshot at $DEVENV_ROOT/state (skipped if none yet)
#   3. install     run the essential modules: base + claude
#                  add --with-node and/or --with-python to opt in to those
#   4. snapshot    refresh $DEVENV_ROOT/state from the live $HOME so the next
#                  rebuild has fresh state (skip with --no-snapshot)
#
# Usage:
#   bash /mnt/shared/debian-env/bootstrap.sh                # essentials + snapshot
#   bash /mnt/shared/debian-env/bootstrap.sh --with-node    # + node toolchain
#   bash /mnt/shared/debian-env/bootstrap.sh --with-python  # + python toolchain
#   bash /mnt/shared/debian-env/bootstrap.sh --all          # every module
#   bash /mnt/shared/debian-env/bootstrap.sh --init-only    # only step 1
#   bash /mnt/shared/debian-env/bootstrap.sh --no-snapshot  # skip step 4
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

while [ $# -gt 0 ]; do
    case "$1" in
        --init-only)    mode="init-only" ;;
        --all)          mode="all" ;;
        --with-node)    with_node=1 ;;
        --with-python)  with_python=1 ;;
        --no-snapshot)  do_snapshot=0 ;;
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

# Restore if either an rsync snapshot or any tar archive exists. Archives
# (e.g. ~/.ssh) may be present even on a first run where snapshot.ts isn't.
has_state=0
[ -f "$DEVENV_SNAPSHOT_DIR/snapshot.ts" ] && has_state=1
for __arch in "$DEVENV_ARCHIVES"/*.tar.gz; do
    [ -f "$__arch" ] && { has_state=1; break; }
done
unset __arch
if [ "$has_state" = 1 ]; then
    devenv restore
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
        mods=(base claude)
        [ "$with_node"   = 1 ] && mods+=(node)
        [ "$with_python" = 1 ] && mods+=(python)
        devenv install "${mods[@]}"
        ;;
esac

# ---- step 4: snapshot ----------------------------------------------------

if [ "$do_snapshot" = 1 ]; then
    devenv snapshot
else
    log "snapshot skipped (--no-snapshot)"
fi

ok "bootstrap: done. Open a new shell or run: source ~/.bashrc"
log "next VM rebuild: re-run \`bash $DEVENV_ROOT/bootstrap.sh\`"
