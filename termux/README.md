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
devpc work logs       # PC-side: a pane per remote tmux session, each an
                      #   auto-reconnecting `ssh pc` (view 'pc-work-logs')
dev -c devenv doctor  # one-off in the guest, no tmux (aliases work: dev -c claudea)
dev doctor            # Termux-side health check (see below)
dev backup            # rootfs backup to <repo>/backups/ (see below)
dev -l / dev -h       # list sessions / usage
```

`devpc NAME...` is the on-PC counterpart of `dev NAME...`: instead of local
guest panes it opens a pane per remote tmux session, each running `sshbab` in
the guest — a loop that `ssh ssh.babanin.de`s and `tmux attach`es (or creates)
session NAME, redialing whenever the Cloudflare tunnel drops and always landing
back in the same session. Sessions are namespaced `pc-NAME-...` so they never
collide with a local `dev NAME...` view. The host config (cloudflared
ProxyCommand, User) is the `Host ssh.babanin.de` stanza the cloudflared module
writes to the guest `~/.ssh/config`; `sshbab` adds its own `ServerAlive*` via
`-o` (the stanza sets none, so a dead tunnel would otherwise hang forever and
the reconnect loop never fire). A clean detach (`Ctrl-b d` on the PC tmux) or
remote exit closes the pane; a dropped link reconnects. `devpc` is a thin
wrapper over `dev` (`DEV_MODE=pc`); `dev` keeps it installed/updated via
self-update. `sshbab` is a standalone guest command too (`sshbab work`) — see
`bin/sshbab`. One-tap launcher: the `devpc-claude-edit` widget opens the
split-screen `claude` + `edit` PC view (`widget/devpc-claude-edit`).

`dev` maintains itself: every run reinstalls `$PREFIX/bin/dev` if the repo
copy changed (then re-execs — editing `termux/bin/dev` is enough, no manual
reinstall), and kicks off a background `devenv snapshot` when the newest one
is older than `DEV_SNAPSHOT_MAX_AGE_DAYS` (default 3, `0` disables; Termux
notification on completion, log at `~/.local/state/devenv/snapshot.log`).
`doctor` and `backup` are reserved words, not usable as pane names.

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

## Persistence (Termux is primary now)

The rootfs + its `$HOME` live in Termux app data: they survive reboots and app
updates, dying only on uninstall / data-clear. Since 2026-06 the guest both
*reads and writes* the devenv snapshots (the old "VM-pure window" policy is
retired with the VM):

- **dotfiles/creds layer** — `devenv snapshot` in the guest, kept fresh
  automatically by `dev`'s staleness check (default: refresh when >3 days
  old). This is what makes a re-bootstrap come back logged in. Re-running
  `termux/bootstrap.sh` over a live guest snapshots *first*, so a stale
  snapshot can't clobber newer creds.
- **whole-rootfs layer** — `dev backup` writes a `proot-distro backup` tar.gz
  to `<repo>/backups/` (keeps `DEV_BACKUP_RETAIN`, default 2). Run it with no
  guest sessions open (it refuses otherwise; `--force` overrides) and the
  phone plugged in — it's several GB. Recovery on a fresh Termux:
  `pkg install proot-distro && proot-distro restore <file>`. Without a rootfs
  backup, recovery = re-run `termux/bootstrap.sh` (~20 min) + snapshot
  restore.

Why no cron for any of this: on Samsung, crond/JobScheduler scheduling is
best-effort at most (doze + OEM killers); the run-on-use staleness check is
the only pattern immune to both. `dev doctor` reports the age of both layers.

Caveat: VM and Termux share one OAuth refresh token — running both regularly
may force a re-login in one. This is a migration, not a dual daily-driver.

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

- `watch` module (systemd) is skipped — no systemd under proot, and it
  couldn't work anyway: `/proc/pressure/*` is permission-denied and `dmesg`
  unavailable in the guest (verified on-device 2026-06-11), so the PSI/OOM
  signals it samples don't exist here. Phantom-kill detection = `dev doctor`
  reminder + `mitigate.sh --verify` after any signal-9.
- File-heavy ops (apt, npm install, big greps) pay proot's ptrace tax — slower than the VM, in exchange for not crashing.
- **Keep working trees in the guest `$HOME`, not `/mnt/shared`**: the shared
  mount adds FUSE on top of the ptrace tax — measured ~3× slower on
  small-file workloads (200-file create+read+delete: 1.6 s in `$HOME` vs
  4.8 s on `/mnt/shared`). The shared mount is for the persistence layer and
  things Android apps must see, not for git checkouts or `node_modules`.
- Random `[Process completed (signal 9)]` → mitigation regressed (an Android update can reset the flag); re-run `mitigate.sh --verify` and recheck the Samsung list.
- Guest commands from the repo `bin/` (`devenv`, `sshbab`, …) are exposed as
  exec-shims in `~/.local/bin` (`/sdcard` has no exec bit, so a symlink into the
  mount can't run). `init.sh` writes these shims for every name in `lib.sh`'s
  `BIN_COMMANDS`, so a bare `devenv init` now refreshes them instead of leaving
  a dead symlink. To add a new guest command: drop it in `bin/`, add its
  basename to `BIN_COMMANDS`, re-run `devenv init` (or `termux/bootstrap.sh`).

## Validation (after first setup)

Re-run `bootstrap.sh` (all steps skip/ok) and `mitigate.sh` ("already
disabled"); `dev` → `devenv doctor` mostly green; `claude --version` logged in
with no onboarding; a 30+ min Claude session with builds and screen off mid-way →
no signal-9; reboot the phone → `dev` → everything intact, no re-bootstrap.
