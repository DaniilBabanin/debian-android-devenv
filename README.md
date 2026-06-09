# devenv — persistent Debian dev environment

Keeps dotfiles, credentials, and an install dispatcher on a host-side mount that
outlives the VM, so a wiped Debian-on-Android install rebuilds to a working
state in one command. Scripts resolve their own root — stage this anywhere
persistent (my setup is at `/mnt/shared/debian-env/`).

## Runtimes

- **AVF VM** — Android's Linux Terminal app (`com.android.virtualization.terminal`). The original target; everything below assumes it.
- **Termux + proot Debian** — runs the *same* core inside proot-distro Debian under [Termux](https://github.com/termux/termux-app), plus a thin Android-side shim (proot setup, phantom-process-killer mitigation, a tmux pane launcher). See [`termux/README.md`](termux/README.md).

`modules/` is the single source of truth for installs; both runtimes consume it
(the Termux shim just calls `bootstrap.sh` in the guest). Add install logic
once — never fork it per runtime.

## Install

Clone to a path that survives reinstalls (on Android, the shared mount):

```bash
git clone https://github.com/<you>/debian-android-devenv.git /mnt/shared/debian-env
```

Fill in `home/.gitconfig` (name/email), and optionally drop `~/.ssh` / `~/.gnupg`
into `archives/` as `tar.gz` before the first bootstrap.

## Bootstrap (after a fresh Debian install)

```bash
bash /mnt/shared/debian-env/bootstrap.sh
```

Symlinks dotfiles → restores state (`~/.config`, history, `~/.ssh`, Claude creds
+ the auth subset of `~/.claude.json` so `claude` stays logged in) → puts
`devenv` on PATH → runs the essential modules (`base claude cloudflared
claude-plugins`) → snapshots the booted state (keeps 3 newest). Add
`--with-node` / `--with-python` / `--all` for more modules, `--no-snapshot` to
skip the final snapshot. Then open a new shell.

## Day-to-day

```bash
devenv list                 # modules + which are installed
devenv install base node    # (re)run modules in order   (or: all)
devenv doctor               # verify symlinks + tool availability
devenv init                 # re-link dotfiles (safe, idempotent)
devenv snapshots            # list retained versions, newest first
devenv restore --rollback   # restore previous version after a bad snapshot
```

## What persists

| Path | Mechanism | Purpose |
|---|---|---|
| `home/.bashrc`, `.gitconfig`, `.inputrc`, `.npmrc`, … | symlink | shell / git / readline / npm config |
| `state/home/.config/` | snapshot dir | XDG configs (nvim, systemd --user, …) |
| `state/home/.bash_history` | snapshot file | history, flushed every command |
| `state/files/.claude/CLAUDE.md` | snapshot file | Claude global guidance (seeded from `home/.claude/CLAUDE.md`) |
| `state/files/.claude/.credentials.json` | snapshot file | Claude auth token (chmod 600 on restore) |
| `state/files/.claude/claude-json-auth.json` | json-merge | auth subset of `~/.claude.json`, merged back on restore |
| `archives/ssh.tar.gz` | tar archive | `~/.ssh` (tar preserves 700/600 across FUSE) |

**Not persisted** (cheap to rebuild): apt packages, Node/nvm, pipx envs, the
Claude binary, and plugins/skills (reinstalled from `modules/claude-*.txt`
manifests). The rest of `~/.claude/` and bulk `~/.claude.json` are deliberately
dropped — bulk-snapshotting either once corrupted the VM — so **`/resume` does
not survive a rebuild**, and persistence inside `~/.claude/` is opt-in per file.
The seeded `CLAUDE.md` tells Claude to track durable state in project-local
`CLAUDE.md` files instead.

## Snapshots & rollback

`devenv snapshot` writes `snapshots/<timestamp>/` and keeps the 3 newest;
`bootstrap.sh` snapshots as its last step, so every retained version comes from a
system that just booted successfully (valid by construction). There is no
shutdown-time snapshot — capturing a possibly-broken moment is exactly what this
avoids.

- `devenv snapshots` — list, newest first.
- `devenv restore [--rollback[=N]]` — restore the newest, or N versions back. Use the rollback form when a fresh `bootstrap.sh` restored a snapshot that breaks the VM. The same flag works on `bootstrap.sh`.

## Extending

**Add a module** — drop `modules/install-<name>.sh` (source `../bin/lib.sh`,
detect-installed-and-exit-0-fast, use `maybe_sudo`/`have`; the dispatcher writes
the success sentinel). Auto-discovered.

**Persist a dotfile** — pick the mechanism by editing the matching array in
`bin/lib.sh`:

| Kind | Array | Storage |
|---|---|---|
| read-mostly dotfile | `LINK_DOTFILES` | symlink from `home/` |
| stateful dir (XDG, SQLite) | `STATEFUL_DIRS` | rsync into `state/home/` |
| single file in a dir you *don't* bulk-snapshot | `SNAPSHOT_FILES` | `state/files/<path>`; `home/<path>` seeds first run |
| a few keys of a JSON file | `CLAUDE_JSON_AUTH_KEYS` | jq-merged (`_snapshot/_restore_claude_json` in `bin/devenv`) |
| needs strict mode bits across FUSE | `ARCHIVE_DIRS` | `archives/<name>.tar.gz` |

Don't put bulk / churny / daemon-written dirs in `STATEFUL_DIRS` — that's how the
`~/.claude/` corruption happened.

**Add a Claude plugin or skill** — append to a manifest, then
`devenv install claude-plugins` (idempotent):

- `modules/claude-marketplaces.txt` — `owner/repo`
- `modules/claude-plugins.txt` — `<plugin>@<marketplace>`
- `modules/claude-skills.txt` — `<git-url> [name]`

## Why this exists

Android 16's Linux Terminal runs Debian in a crosvm VM (AVF). It's experimental,
the disk lives in unreachable app-private storage, and two failure modes force
reinstalls: an ungraceful shutdown (app swipe / OOM kill) poisons the next boot
(crash-loop → the dev-options toggle that "fixes" it wipes the disk), and
half-written state on `/mnt/shared` (virtio-fs, no reliable locking or atomic
rename) corrupts files that take down the next launch. This repo assumes the
wipes keep happening and makes recovery cheap.

## Gotchas

- **Never `cp` when any path is under `/mnt/shared`** — use `rsync`. The FUSE/sdcardfs bridge can crash the VM mid-copy (zero-length files, hang, app reset).
- `/mnt/shared` may not honor mode bits — that's why `~/.ssh` / `~/.gnupg` go through `ARCHIVE_DIRS` tar, not `home/`.
- `~/.claude/` is not bulk-snapshotted and `~/.claude.json` carries only its auth subset (both corrupted the VM whole) — MCP registrations and other fields don't survive; re-add after a rebuild.
- Concurrent shells interleave `.bash_history` despite the `history -a` PROMPT_COMMAND.
- `devenv init` backs up real files to `~/.devenv-backup/<timestamp>/` before linking — safe to re-run.
