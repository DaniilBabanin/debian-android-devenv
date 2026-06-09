#!/usr/bin/env bash
# termux/mitigate.sh — disable Android's phantom-process killer + print the
# Samsung keep-alive checklist.
#
# Why: Android 12+ SIGKILLs an app's child processes once >32 exist system-wide
# or one burns "too much" CPU — a multi-process agent session (Claude Code
# spawning compilers/git/tests) is the pathological case. Symptom in Termux:
# [Process completed (signal 9)].
#
# The fix is one global settings flag, written once over adb, persistent across
# reboots. No PC needed: Termux pairs with the device's own Wireless debugging.
#
# Run:      bash ~/storage/shared/Sync/debian-env/termux/mitigate.sh
# Re-run:   reports "already applied" from a local marker (the real state sits
#           behind adb, and wireless-adb ports rotate every boot — re-pairing
#           just to look is not worth it).
# --verify: ignore the marker and re-check the live setting over adb
#           (use after an Android update or if signal-9 kills reappear).

set -euo pipefail

log()  { printf '\033[34m[mitigate]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

command -v adb >/dev/null 2>&1 || die "adb missing — run termux/bootstrap.sh first (installs android-tools)"

MARKER="${XDG_STATE_HOME:-$HOME/.local/state}/devenv-mitigate.done"
force_verify=0
[ "${1:-}" = "--verify" ] && force_verify=1

if [ -f "$MARKER" ] && [ "$force_verify" = 0 ]; then
    ok "phantom-killer mitigation already applied: $(cat "$MARKER")"
    log "the settings flag persists across reboots; re-check the live value with: bash ${BASH_SOURCE[0]} --verify"
    exit 0
fi

# ---- connect over Wireless debugging -----------------------------------------
if ! adb get-state >/dev/null 2>&1; then
    cat <<'EOF'

adb is not connected. One-time pairing with this device:

  1. Settings -> Developer options -> Wireless debugging -> ON
     (no Developer options? Settings -> About phone -> tap "Build number" 7x)
  2. Open Termux and Settings in SPLIT SCREEN (the pairing dialog must stay
     visible — it closes when Settings loses focus).
  3. In Wireless debugging tap "Pair device with pairing code".
     Note the 6-digit CODE and the PORT shown under the dialog's IP address.

EOF
    read -rp "pairing PORT (shown as 'IP address & port' INSIDE the pairing dialog): " pair_port
    read -rp "6-digit pairing CODE (large digits in the same dialog): " pair_code
    adb pair "127.0.0.1:$pair_port" "$pair_code" || die "pairing failed — redo from the dialog (it shows a fresh code each time)"
    cat <<'EOF'

  4. Back on the Wireless debugging MAIN screen, note the port in
     "IP address & Port" (different from the pairing port).

EOF
    read -rp "connect port: " conn_port
    adb connect "127.0.0.1:$conn_port" || die "connect failed"
    adb get-state >/dev/null 2>&1 || die "device did not come up over adb"
fi
ok "adb connected"

# ---- apply / verify the phantom-process setting --------------------------------
release="$(adb shell getprop ro.build.version.release </dev/null | tr -d '[:space:]')"
log "android version: ${release:-unknown}"

current="$(adb shell settings get global settings_enable_monitor_phantom_procs </dev/null | tr -d '[:space:]')"
if [ "$current" = "false" ]; then
    ok "phantom-process monitoring already disabled (settings flag = false)"
else
    log "current settings flag: ${current:-unset} — disabling"
    adb shell settings put global settings_enable_monitor_phantom_procs false </dev/null
fi

# Android 12 (only): GMS rewrites device_config ~minutes after boot unless sync
# is pinned; 12L+ honors the settings flag alone.
if [ "$release" = "12" ]; then
    log "android 12: pinning device_config against GMS overwrite"
    adb shell /system/bin/device_config set_sync_disabled_for_tests persistent </dev/null || warn "set_sync_disabled_for_tests failed"
    adb shell /system/bin/device_config put activity_manager max_phantom_processes 2147483647 </dev/null || warn "max_phantom_processes failed"
fi

verify="$(adb shell settings get global settings_enable_monitor_phantom_procs </dev/null | tr -d '[:space:]')"
if [ "$verify" = "false" ]; then
    ok "verified: settings_enable_monitor_phantom_procs = false (persists across reboot)"
    mkdir -p "$(dirname "$MARKER")"
    printf '%s android-%s\n' "$(date -Iseconds)" "${release:-unknown}" > "$MARKER"
else
    warn "verification failed (got: ${verify:-empty}) — re-run, or check adb connection"
    rm -f "$MARKER"
fi

adb kill-server >/dev/null 2>&1 || true

# ---- the part adb can't do ------------------------------------------------------
cat <<'EOF'

manual checklist (one-time, persists — Samsung is an aggressive killer):

  [ ] Settings -> Apps -> Termux -> Battery -> "Unrestricted"
  [ ] Settings -> Battery -> Background usage limits:
        remove Termux from "Sleeping apps" / "Deep sleeping apps",
        add it to "Never sleeping apps"
  [ ] Settings -> Battery: keep "Adaptive battery" off, or at least
      Power saving mode OFF while running long sessions
  [ ] Android 14+ belt-and-suspenders: Developer options ->
      "Disable child process restrictions" -> ON
      (reverts only if you ever turn Developer options off)

per-session habits (the `dev` wrapper handles the wake-lock):
  - don't swipe Termux out of recents; leave its notification alone
  - long jobs: keep the phone plugged in
  - work lives in tmux — if the UI dies, `dev` reattaches the session

the settings flag persists across reboots. If signal-9 kills ever reappear
(Android update can reset it), re-check the live value:
  bash termux/mitigate.sh --verify
EOF
