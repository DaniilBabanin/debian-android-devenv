# devenv on Termux (proot-distro Debian)

The AVF terminal VM is unstable (GrapheneOS tracker #5718 / #6375 / #5733 —
phone-crashing installs, corrupt VM configs). This runs the **same devenv
unchanged** inside proot-distro Debian on Termux.

Why proot and not native Termux: Claude Code ships a glibc binary that segfaults
on bionic, and the npm fallback is frozen at v2.1.112
(anthropics/claude-code#50270). proot Debian gives real glibc — the official
installer and the apt-based modules just work.

| layer | runs | owns |
|---|---|---|
| Termux (bionic) | `termux/` scripts | wake-lock, tmux server, proot lifecycle, kill-mitigation |
| proot Debian (glibc, trixie) | core `bootstrap.sh` + modules | apt tools, dotfiles, Claude Code |
| repo on shared storage | bound to `/mnt/shared` in the guest | **paths identical to the VM** |

## Setup

Install Termux from [GitHub releases](https://github.com/termux/termux-app/releases)
or F-Droid — never the Play Store build, never mix sources. Then:

```bash
termux-setup-storage                                          # grant storage permission
bash ~/storage/shared/Sync/debian-env/termux/bootstrap.sh     # ~20 min
bash ~/storage/shared/Sync/debian-env/termux/mitigate.sh      # one-time, don't skip
```

- **bootstrap** installs Termux pkgs (proot-distro, tmux, termux-api, android-tools) + the Debian rootfs, then runs the core devenv bootstrap inside it (`--no-snapshot base claude cloudflared claude-plugins`). Restore seeds Claude creds, `~/.ssh`, `.config`, and history from the VM snapshots — logged in from first launch.
- **mitigate** disables Android's phantom-process killer (>32 system-wide children → SIGKILL; a Claude session spawning compilers/git/tests is the worst case) via the device's own Wireless debugging — no PC needed, persists across reboots. Also prints the one-time Samsung battery checklist.

## Daily entry: `dev`

```bash
dev                   # workspace: split-screen (DEV_PANES, default 2)
dev claude builds     # a tiled guest pane per name — and the name-set IS the
                      #   session ('claude-builds'), independent per Termux tab
dev claude            # single name zooms that pane full-screen
dev -p 3              # grow to N panes (grow-only, never kills)
dev -s other claude   # force the session name (override the derived one)
dev -c devenv doctor  # one-off in the guest, no tmux (aliases work: dev -c claudea)
dev -l / dev -h       # list sessions / usage
```

Inside it's `claudea`, `devenv doctor`, `devenv install <mod>` — same as the VM.
Layout follows pane count: 2 = side-by-side halves, 3 = first pane full left +
two stacked right, 4+ = grid. Extra `Ctrl-b %` / `"` splits auto-login to the
guest and re-tile.

Keys: tap a pane to focus (mouse on), `Ctrl-b z` zoom/unzoom one pane (the phone
gesture), `Ctrl-b arrows` move, `Ctrl-b d` detach. Soft-keyboard taps go to
tmux — reopen it with the KEYBOARD extra key. `PgUp` scrolls (enters copy-mode);
full-screen apps (Claude Code, less, vim) get raw `PgUp`. A finger-drag selects
within the active pane; Termux long-press selection ignores panes (spans the
screen) — zoom the pane first if you need it.

## Persistence (differs from the VM)

The rootfs + its `$HOME` live in Termux app data: they survive reboots and app
updates, dying only on uninstall / data-clear. **No frequent rebuilds** — the
guest *reads* VM snapshots (creds/ssh/config seeding) but never *writes* them
(`--no-snapshot` is hard-coded), so the VM's retained-3 window stays pure.
Disaster recovery = re-run `termux/bootstrap.sh`, restore re-seeds.

Caveat: VM and Termux share one OAuth refresh token — running both regularly may
force a re-login in one. This is a migration, not a dual daily-driver.

## Phone notifications from PC-side Claude

When you `ssh pc` from the guest and Claude Code there blocks on input, the phone
gets a Termux notification:

```
PC Notification hook (bin/claude-phone-notify) → 127.0.0.1:9876
  → ssh RemoteForward (stanzas from install-cloudflared.sh) → guest :9876
  → claude-notify-listen (socat, lazy via ssh LocalCommand) → termux-notification
```

Works only while an ssh session to the PC is up — which is exactly when you'd be
waiting on PC-side Claude. The PC isn't bootstrap-managed: on reinstall, copy
`bin/claude-phone-notify` to PC `~/.local/bin/` (chmod 755) and register it as a
Notification hook in the PC's `~/.claude/settings.json`.

## Limits / debugging

- `watch` module (systemd) is skipped — no systemd under proot; `devenv probe` degrades gracefully.
- File-heavy ops (apt, npm install, big greps) pay proot's ptrace tax — slower than the VM, in exchange for not crashing.
- Random `[Process completed (signal 9)]` → mitigation regressed (an Android update can reset the flag); re-run `mitigate.sh --verify` and recheck the Samsung list.
- `devenv` in the guest is an exec-wrapper (`/sdcard` has no exec bit, so the symlink `init.sh` creates can't run). A bare `devenv init` re-creates that broken symlink — re-run `termux/bootstrap.sh` to re-fix if `devenv` stops resolving.

## Validation (after first setup)

Re-run `bootstrap.sh` (all steps skip/ok) and `mitigate.sh` ("already
disabled"); `dev` → `devenv doctor` mostly green; `claude --version` logged in
with no onboarding; a 30+ min Claude session with builds and screen off mid-way →
no signal-9; reboot the phone → `dev` → everything intact, no re-bootstrap.
