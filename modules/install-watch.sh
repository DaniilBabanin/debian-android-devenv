#!/usr/bin/env bash
# install-watch.sh — install + enable the degradation watcher as a systemd
# --user service. The watcher (`devenv watch`) is near-silent when the VM is
# calm and records one coalesced episode (with the culprit process tree) to
# metrics/episodes.jsonl only when PSI stall / low-mem / OOM trips. See
# docs/harden-spec.md.
#
# Why a module (not a one-off): the VM root is ephemeral — the unit file under
# ~/.config/systemd/user/ and its enable-state are wiped on rebuild, so this
# re-installs from the persisted source (units/devenv-watch.service) and
# re-enables on every bootstrap. The unit itself is EXCLUDED from snapshots
# (see the rsync excludes in `devenv` snapshot) so it stays a reproducible
# artifact, not carried state.
set -euo pipefail
__self="${BASH_SOURCE[0]}"
while [ -L "$__self" ]; do __self="$(readlink -f "$__self")"; done
# shellcheck disable=SC1091
source "$(dirname "$__self")/../bin/lib.sh"

unit_name="devenv-watch.service"
unit_src="$DEVENV_ROOT/units/$unit_name"
unit_dst="$HOME/.config/systemd/user/$unit_name"

[ -f "$unit_src" ] || die "watch: missing unit source $unit_src"

if ! have systemctl; then
    warn "watch: systemctl not available — cannot install user service; skipping"
    exit 0
fi

step "install watcher unit"
mkdir -p "$(dirname "$unit_dst")"
# Source is under /mnt/shared — rsync, never cp (cp on the shared mount can
# crash the VM). Dest is VM-local ($HOME on ext4).
if have rsync; then
    rsync -a --no-links -- "$unit_src" "$unit_dst"
else
    # Fallback only valid because the SOURCE read is fine; the hazard is cp's
    # write path on the shared mount, which isn't involved here (dest is local).
    install -m 0644 "$unit_src" "$unit_dst"
fi
ok "installed $unit_dst"

step "enable watcher"
systemctl --user daemon-reload 2>/dev/null || warn "watch: daemon-reload failed (no --user bus?)"
if systemctl --user enable --now "$unit_name" 2>/dev/null; then
    ok "enabled + started $unit_name"
else
    warn "watch: enable --now failed — is the systemd --user instance up? (loginctl enable-linger may be needed)"
fi

# Verify it's actually running; surface state either way.
if systemctl --user is-active --quiet "$unit_name" 2>/dev/null; then
    ok "watch: $unit_name active"
else
    warn "watch: $unit_name not active — check: systemctl --user status $unit_name"
fi

ok "watch module done"
