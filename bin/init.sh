#!/usr/bin/env bash
# Link read-mostly dotfiles from $DEVENV_HOME into $HOME, with backups.
# Stateful dirs (.claude, .config, .bash_history) are NOT linked — they're
# managed via `devenv snapshot` / `devenv restore`. Safe to re-run.

set -euo pipefail
__self="${BASH_SOURCE[0]}"
while [ -L "$__self" ]; do __self="$(readlink -f "$__self")"; done
# shellcheck disable=SC1091
source "$(dirname "$__self")/lib.sh"

step "linking dotfiles from $DEVENV_HOME into $HOME"

# Single timestamp for the whole run so all backups land in one folder.
export DEVENV_BACKUP_TS="$(date +%Y%m%d-%H%M%S)"

# Symlink LINK_DOTFILES (declared in lib.sh).
for entry in "${LINK_DOTFILES[@]}"; do
    [ -e "$DEVENV_HOME/$entry" ] || continue
    backup_then_link "$entry"
done

# Migration: a previous version of init.sh symlinked .claude / .config /
# .bash_history out of $DEVENV_HOME. Those entries are now stateful and must
# be real files/dirs in $HOME, not symlinks into /mnt/shared. Unlink them so
# `devenv restore` (or a fresh app run) can populate them safely.
#
# Also unlink any legacy symlink for the top-level component of a
# SNAPSHOT_FILES entry — e.g. a leftover `~/.claude -> $DEVENV_HOME/.claude`
# would cause _restore_file to write CLAUDE.md into the template itself.
declare -A _legacy_seen=()
_unlink_legacy() {
    local name="$1"
    local dst="$HOME/$name"
    [ -n "${_legacy_seen[$name]:-}" ] && return 0
    _legacy_seen[$name]=1
    [ -L "$dst" ] || return 0
    target="$(readlink "$dst")"
    case "$target" in
        "$DEVENV_HOME/$name"|"$DEVENV_HOME/$name/")
            warn "unlinking legacy symlink ~/$name -> $target"
            rm -- "$dst"
            ;;
        *)
            warn "~/$name is a symlink to $target — leaving it alone (not ours)"
            ;;
    esac
}

for stateful in "${STATEFUL_DIRS[@]}"; do
    _unlink_legacy "$stateful"
done

# Top-level component of each SNAPSHOT_FILES entry (e.g. `.claude` from
# `.claude/CLAUDE.md`).
for snap_rel in "${SNAPSHOT_FILES[@]}"; do
    _unlink_legacy "${snap_rel%%/*}"
done

# Put `devenv` on PATH via ~/.local/bin
mkdir -p "$HOME/.local/bin"
if [ ! -L "$HOME/.local/bin/devenv" ] || [ "$(readlink "$HOME/.local/bin/devenv")" != "$DEVENV_BIN/devenv" ]; then
    ln -sf "$DEVENV_BIN/devenv" "$HOME/.local/bin/devenv"
    ok "linked ~/.local/bin/devenv -> $DEVENV_BIN/devenv"
fi

# Retire the shutdown snapshot unit. Snapshots are now taken on successful boot
# (bootstrap step 4), so the old ExecStop-on-shutdown unit is removed: it
# captured arbitrary, possibly-broken state and would push good versions out of
# the retained window.
unit_name="devenv-snapshot.service"
unit_dst="$HOME/.config/systemd/user/$unit_name"
if have systemctl && systemctl --user --version >/dev/null 2>&1; then
    if systemctl --user is-enabled --quiet "$unit_name" 2>/dev/null; then
        systemctl --user disable "$unit_name" >/dev/null 2>&1 && ok "disabled legacy $unit_name" || true
    fi
fi
if [ -f "$unit_dst" ]; then
    rm -f -- "$unit_dst"
    ok "removed legacy $unit_name"
fi

ok "init complete. Start a new shell or run: source ~/.bashrc"
