#!/usr/bin/env bash
# Shared helpers for devenv. Source this; do not execute directly.

set -o pipefail

# Resolve DEVENV_ROOT from this file's location so the whole tree is portable
# (works whether installed at /mnt/shared/debian-env or staged elsewhere).
__lib_path="${BASH_SOURCE[0]}"
while [ -L "$__lib_path" ]; do
    __lib_path="$(readlink -f "$__lib_path")"
done
DEVENV_BIN="$(cd "$(dirname "$__lib_path")" && pwd)"
DEVENV_ROOT="$(cd "$DEVENV_BIN/.." && pwd)"
DEVENV_HOME="$DEVENV_ROOT/home"
DEVENV_MODULES="$DEVENV_ROOT/modules"
# Module install sentinels (one file per installed module).
DEVENV_STATE="$DEVENV_ROOT/archives/state"
# Snapshot/restore target for STATEFUL_DIRS — host of dpkg-selections.txt,
# apt-manual.txt, snapshot.ts, and home/<name>/.
DEVENV_SNAPSHOT_DIR="$DEVENV_ROOT/state"
export DEVENV_ROOT DEVENV_BIN DEVENV_HOME DEVENV_MODULES DEVENV_STATE DEVENV_SNAPSHOT_DIR

# What gets symlinked from $DEVENV_HOME into $HOME by init.sh.
# Read-mostly dotfiles ONLY — these tolerate the virtio-fs / sdcardfs quirks
# (no POSIX locking, no atomic rename) on /mnt/shared.
LINK_DOTFILES=(
    .bashrc
    .bash_profile
    .profile
    .inputrc
    .gitconfig
    .npmrc
)

# What gets snapshot/restored instead of symlinked. Anything that does SQLite,
# WAL, flock(), or write-tmp-then-rename MUST go here, not in LINK_DOTFILES.
# .bash_history is a file rather than a directory; snapshot/restore handle both.
STATEFUL_DIRS=(
    .claude
    .claude.json
    .config
    .bash_history
)

# Directories archived as tar.gz under $DEVENV_ROOT/archives/. Use this for
# anything that needs strict mode bits (~/.ssh wants 700/600, ~/.gnupg too):
# the shared mount is FUSE/sdcardfs and rsync-snapshotting strips perms, but
# tar bakes mode into archive metadata so extraction restores them.
ARCHIVE_DIRS=(
    .ssh
)
DEVENV_ARCHIVES="$DEVENV_ROOT/archives"
export DEVENV_ARCHIVES

# Colours (skip if NO_COLOR or non-tty)
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_DIM=''
fi

log()   { printf '%s[devenv]%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()    { printf '%s[ ok ]%s %s\n'   "$C_GRN" "$C_RESET" "$*"; }
warn()  { printf '%s[warn]%s %s\n'   "$C_YLW" "$C_RESET" "$*" >&2; }
err()   { printf '%s[fail]%s %s\n'   "$C_RED" "$C_RESET" "$*" >&2; }
step()  { printf '\n%s==>%s %s%s%s\n' "$C_BLU" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }

die() { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Run a command with sudo only if we're not already root.
maybe_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif have sudo; then
        sudo "$@"
    else
        die "need root or sudo for: $*"
    fi
}

# backup_then_link <target-under-home> <source-under-DEVENV_HOME>
# Idempotent: if already correctly linked, no-op.
backup_then_link() {
    local rel="$1"
    local src="$DEVENV_HOME/$rel"
    local dst="$HOME/$rel"

    [ -e "$src" ] || { warn "skip $rel — source missing in devenv/home"; return 0; }

    mkdir -p "$(dirname "$dst")"

    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        return 0
    fi

    if [ -e "$dst" ] || [ -L "$dst" ]; then
        local ts="${DEVENV_BACKUP_TS:-$(date +%Y%m%d-%H%M%S)}"
        local bdir="$HOME/.devenv-backup/$ts"
        mkdir -p "$bdir/$(dirname "$rel")"
        mv "$dst" "$bdir/$rel"
        warn "backed up existing $dst -> $bdir/$rel"
    fi

    ln -s "$src" "$dst"
    ok "linked ~/$rel -> $src"
}

sentinel_path()  { printf '%s/%s.installed\n' "$DEVENV_STATE" "$1"; }
sentinel_set()   { mkdir -p "$DEVENV_STATE"; date -Iseconds > "$(sentinel_path "$1")"; }
sentinel_check() { [ -f "$(sentinel_path "$1")" ]; }

# List module names (basename without install- prefix and .sh suffix)
list_modules() {
    local f name
    for f in "$DEVENV_MODULES"/install-*.sh; do
        [ -e "$f" ] || continue
        name="$(basename "$f")"; name="${name#install-}"; name="${name%.sh}"
        printf '%s\n' "$name"
    done
}

# Run one module by name, with the lib already sourced for it.
run_module() {
    local name="$1"
    local script="$DEVENV_MODULES/install-$name.sh"
    [ -f "$script" ] || die "unknown module: $name (looked for $script)"
    step "module: $name"
    # shellcheck disable=SC1090
    DEVENV_MODULE_NAME="$name" bash "$script" || die "module $name failed"
    sentinel_set "$name"
    ok "module $name done"
}
