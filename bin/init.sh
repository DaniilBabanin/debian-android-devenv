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
for stateful in "${STATEFUL_DIRS[@]}"; do
    dst="$HOME/$stateful"
    if [ -L "$dst" ]; then
        target="$(readlink "$dst")"
        case "$target" in
            "$DEVENV_HOME/$stateful"|"$DEVENV_HOME/$stateful/")
                warn "unlinking legacy symlink ~/$stateful -> $target"
                rm -- "$dst"
                ;;
            *)
                warn "~/$stateful is a symlink to $target — leaving it alone (not ours)"
                ;;
        esac
    fi
done

# Put `devenv` on PATH via ~/.local/bin
mkdir -p "$HOME/.local/bin"
if [ ! -L "$HOME/.local/bin/devenv" ] || [ "$(readlink "$HOME/.local/bin/devenv")" != "$DEVENV_BIN/devenv" ]; then
    ln -sf "$DEVENV_BIN/devenv" "$HOME/.local/bin/devenv"
    ok "linked ~/.local/bin/devenv -> $DEVENV_BIN/devenv"
fi

# Install the systemd --user unit that snapshots on shutdown.
unit_name="devenv-snapshot.service"
unit_src="$DEVENV_HOME/.config/systemd/user/$unit_name"
unit_dst_dir="$HOME/.config/systemd/user"
unit_dst="$unit_dst_dir/$unit_name"

if [ -f "$unit_src" ]; then
    mkdir -p "$unit_dst_dir"
    if ! cmp -s "$unit_src" "$unit_dst" 2>/dev/null; then
        cp -- "$unit_src" "$unit_dst"
        ok "installed $unit_name -> $unit_dst"
    fi

    if have systemctl && systemctl --user --version >/dev/null 2>&1; then
        if systemctl --user is-enabled --quiet "$unit_name" 2>/dev/null; then
            ok "$unit_name already enabled"
        elif systemctl --user enable "$unit_name" >/dev/null 2>&1; then
            ok "enabled $unit_name"
        else
            warn "could not enable $unit_name (systemctl --user not usable in this VM)"
        fi
    else
        warn "systemctl --user unavailable — skipping enable of $unit_name"
    fi
else
    warn "systemd unit source missing: $unit_src"
fi

ok "init complete. Start a new shell or run: source ~/.bashrc"
