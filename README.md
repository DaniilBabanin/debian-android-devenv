# devenv — persistent Debian dev environment

Survives full reinstalls of the Debian-on-Android emulator (or any
throwaway Debian rootfs) by keeping dotfiles and an install dispatcher on a
host-side mount that outlives the VM. My setup lives at
`/mnt/shared/debian-env/`. The scripts resolve their own root, so stage
this anywhere persistent and the same commands work.

## Why this exists

Android 16 ships a Linux Terminal app (`com.android.virtualization.terminal`) that runs Debian inside a crosvm-backed VM via the Android Virtualization Framework. It's marked experimental, the VM disk lives in app-private storage you can't reach without root, and a few common failure modes leave you reinstalling from scratch:

- **Ungraceful shutdown poisons next boot.** Swiping the app away, OOM kills, or the Android low-memory killer reaping the VM leaves the disk in a state where the next launch hits a `RejectedExecutionException` in the app's logger, or crash-loops with a system reset within ~2 seconds of boot. Recovery is the developer-options toggle (Settings → Developer options → Linux development environment → off and on), which wipes the disk.
- **Half-written state on the shared mount cascades.** `/mnt/shared` is bridged through virtio-fs to Android's MediaProvider-backed storage. POSIX file locking and atomic rename semantics are unreliable there, so any tool that puts SQLite, lockfiles, or write-tmp-then-rename state on it can leave behind corrupt files that take down the next launch.

This repo assumes the wipes will keep happening and makes recovery cheap. It stores a portable, idempotent description of the dev environment on Android shared storage (`/storage/emulated/0` → `/mnt/shared` inside the VM) and rebuilds a fresh Debian install to a working state in one command. The snapshot/restore split exists because of the virtio-fs limits above: stateful directories live on the VM's ext4, not on `/mnt/shared`. Only tar-packed archives, which bake permissions into metadata, round-trip safely through the shared mount.

## Install

Clone (or copy) this repo to a path that survives Debian reinstalls. For
Android emulators, that's the shared storage mount:

```bash
git clone https://github.com/<you>/debian-android-devenv.git /mnt/shared/debian-env
```

Then fill in `home/.gitconfig` with your name and email (the committed file
has commented-out placeholders), and optionally drop your own `~/.ssh` or
`~/.gnupg` into `archives/` as tar.gz before the first bootstrap.

## After a fresh Debian install

```bash
bash /mnt/shared/debian-env/bootstrap.sh 
```

That:

1. Symlinks read-mostly dotfiles (`~/.bashrc`, `~/.gitconfig`, …) into `$HOME`.
2. Restores stateful dirs (`~/.config`, `~/.bash_history`), tar archives (`~/.ssh`), per-file snapshots (`~/.claude/CLAUDE.md`, `~/.claude/.credentials.json`), and the auth subset of `~/.claude.json` merged back into the live file so `claude` stays logged in — seeding `~/.claude/CLAUDE.md` from the shipped template on first run.
3. Puts `devenv` on PATH at `~/.local/bin/devenv`.
4. Runs the essential install modules (`base`, `claude`, `claude-plugins`). Pass `--with-node` / `--with-python` / `--all` to include the others.
5. Snapshots the live state into a new versioned `snapshots/<timestamp>/` (keeping the 3 newest) so the next rebuild has fresh, valid-by-construction data — and a rollback target if it ever breaks.

Then open a new shell (or `source ~/.bashrc`).

## Day-to-day

```bash
devenv list                       # show modules + which are marked installed
devenv install node               # (re)run one module
devenv install base node          # run several in order
devenv install all                # full toolchain
devenv doctor                     # verify symlinks + tool availability
devenv init                       # re-link dotfiles (idempotent, safe)
devenv sync                       # if home/ is a git repo, show drift
devenv snapshots                  # list retained snapshot versions (newest first)
devenv restore --rollback         # restore the previous version (after a bad snapshot)
```

## What persists

Anything you'd otherwise have to rewrite from memory after a reinstall:

| Path | Mechanism | Purpose |
|---|---|---|
| `home/.bashrc`, `.bash_profile`, `.profile` | symlink | shell config |
| `home/.inputrc` | symlink | readline tweaks |
| `home/.gitconfig` | symlink | git identity + aliases |
| `home/.npmrc` | symlink | npm config |
| `state/home/.config/` | snapshot dir | XDG configs (nvim, systemd --user units, etc.) |
| `state/home/.bash_history` | snapshot file | full history; flushed every command |
| `state/files/.claude/CLAUDE.md` | snapshot file | Claude Code global guidance (seeded from `home/.claude/CLAUDE.md` on first run, then snapshotted) |
| `state/files/.claude/.credentials.json` | snapshot file | Claude Code auth token (chmod 600 on restore) |
| `state/files/.claude/claude-json-auth.json` | json-merge subset | auth keys extracted from `~/.claude.json` (`oauthAccount`, `userID`, `hasCompletedOnboarding`) — merged back into the live file on restore so `claude` stays logged in across rebuilds without snapshotting the corruption-prone whole file |
| `archives/ssh.tar.gz` | tar archive | `~/.ssh` — keys, `known_hosts`, `authorized_keys` (tar preserves 700/600 perms across FUSE) |

What doesn't persist, because reinstalling is cheap and the modules re-establish it:

- apt packages (re-installed by `install-base`)
- `~/.nvm/` and Node binaries (re-installed by `install-node`)
- pipx envs (re-installed by `install-python`)
- the Claude binary itself (re-installed by `install-claude`)
- Claude Code plugins, marketplaces, and user-installed skills (re-installed by `install-claude-plugins` from manifests in `modules/claude-{marketplaces,plugins,skills}.txt`)
- the rest of `~/.claude/` — sessions, `projects/`, the auto-memory system, `file-history/`, `settings.json`, telemetry. The bulk of `~/.claude.json` is also wiped (only the auth subset listed above survives, merged back into a fresh file on restore). **`/resume` does not survive a VM rebuild.** A bulk `~/.claude/` snapshot once corrupted the VM, so persistence inside that directory is now opt-in per file via `SNAPSHOT_FILES` in `bin/lib.sh`. The seeded `~/.claude/CLAUDE.md` instructs Claude Code to track durable project state in project-local `CLAUDE.md` files instead of relying on the auto-memory system.

## Snapshots & rollback

Snapshots are **versioned**. Each `devenv snapshot` writes a new
`snapshots/<timestamp>/` directory and keeps the **3 newest**. `bootstrap.sh`
takes a snapshot automatically as its final step, so every retained version
comes from a system that just booted successfully — valid by construction. A
`meta` file written last marks a version complete (the shared mount has no
atomic rename).

- `devenv snapshots` — list the retained versions, newest first; the newest is
  what a plain restore uses.
- `devenv restore` — restore the newest version (this is what `bootstrap.sh`
  does).
- `devenv restore --rollback` — restore the version before newest. Use this when
  a fresh `bootstrap.sh` restored a snapshot that breaks the VM.
- `devenv restore --rollback=2` — go two versions back.
- `bash bootstrap.sh --rollback[=N]` — same, during a full rebuild.

The first run of the versioned `devenv snapshot` migrates any pre-existing
single-copy snapshot (`state/` + `archives/ssh.tar.gz`) into `snapshots/` as
version 1, so no existing state is lost. There is no shutdown-time snapshot:
capturing state at an arbitrary (possibly broken) moment is exactly what the
versioned, boot-only model avoids.

## Telling Claude about the installed tools

The repo ships `home/.claude/CLAUDE.md`, which seeds `~/.claude/CLAUDE.md`
the first time `bootstrap.sh` runs on a fresh VM (after that, your edits to
`~/.claude/CLAUDE.md` are snapshotted back via `SNAPSHOT_FILES`). It tells the
agent:

- Track durable project state in **project-local** `CLAUDE.md` files at the
  working-directory root, since `~/.claude/projects/<wd>/{sessions,memory}/`
  are wiped on every VM rebuild and `/resume` doesn't survive.
- Never use `cp` when any path is under `/mnt/shared` — use `rsync` instead.
  The virtio-fs bridge can crash the VM mid-copy.
- What CLI tools are on PATH (full inventory mirroring the install modules),
  so Claude reaches for the right tool instead of falling back to whatever it
  knows from training.
- Where to append missing-tool requests
  (`/mnt/shared/debian-env/tool-wishlist.md`).

Edit `home/.claude/CLAUDE.md` to tailor it. If you cloned somewhere other
than `/mnt/shared/debian-env`, update the path references in that file.

## Adding a module

Drop `modules/install-<name>.sh` into `modules/`. The dispatcher picks it up automatically.

Module contract:

- Source `../bin/lib.sh` at the top.
- Detect already-installed state and exit 0 fast.
- Use `maybe_sudo` for root-required commands.
- Use `have <cmd>` to test for tools.
- The dispatcher writes the success sentinel; your module just needs to exit 0.

## Adding a dotfile to persist

Pick the right mechanism for the file:

- **Read-mostly dotfile** (`.bashrc`, `.gitconfig`, …) — put under `home/`, add its name to `LINK_DOTFILES` in `bin/lib.sh`, run `devenv init` to symlink it into `$HOME`. Whole directories are linked as one symlink, so anything underneath is automatic.
- **Stateful directory** (XDG dirs, SQLite-backed apps) — add to `STATEFUL_DIRS` in `bin/lib.sh`. Managed by `devenv snapshot` / `devenv restore` via rsync into `state/home/<name>/`. Don't put anything bulk-misbehaving here (large opaque dir, frequent churn, daemons writing while a snapshot runs) — that's how the original `~/.claude/` corruption happened.
- **Single file inside a directory you deliberately don't bulk-snapshot** (e.g. `~/.claude/CLAUDE.md`) — add the `$HOME`-relative path to `SNAPSHOT_FILES` in `bin/lib.sh`. Snapshot/restore handles one file at a time, writing to `state/files/<path>`. A matching file under `home/<path>` acts as a first-run seed template (used by `devenv restore` when no snapshot exists yet).
- **JSON file you only want a few keys from** (e.g. `~/.claude.json` — bulk-snapshotting corrupts it, but the auth fields are worth carrying across rebuilds) — handled as a one-off in `bin/devenv` (`_snapshot_claude_json` / `_restore_claude_json`) with the key list in `CLAUDE_JSON_AUTH_KEYS` in `bin/lib.sh`. Snapshot extracts the subset via `jq`; restore merges it back into the live file (snapshot keys override live, live-only keys survive), so the file is never replaced wholesale.
- **Anything needing strict mode bits across FUSE/sdcardfs** (`~/.ssh`, `~/.gnupg`) — add to `ARCHIVE_DIRS` in `bin/lib.sh`. Stored as `archives/<name>.tar.gz` so perms survive the round-trip.

## Adding a Claude Code plugin or skill

Plugins and skills aren't persisted directly — they're reinstalled from manifests on each rebuild via `modules/install-claude-plugins.sh`:

- Marketplace: append a source to `modules/claude-marketplaces.txt` (e.g. `anthropics/claude-plugins-official` or any GitHub `owner/repo`).
- Plugin: append `<plugin>@<marketplace>` to `modules/claude-plugins.txt`.
- Skill: append `<git-url> [name]` to `modules/claude-skills.txt` (cloned shallow into `~/.claude/skills/<name>`).

`devenv install claude-plugins` (re)runs the install. Idempotent — already-installed entries are skipped, so it's safe to re-run after editing the manifests.

## Risks and known limits

- `/mnt/shared/` on Android is typically FUSE/sdcardfs and may not honor unix mode bits. That's why `~/.ssh` lives in `archives/ssh.tar.gz` (tar bakes 700/600 into the archive metadata) instead of `home/.ssh/` (which would lose perms on the FUSE round-trip). `~/.gnupg` would need the same treatment; see `ARCHIVE_DIRS` in `bin/lib.sh` to add more.
- Never use `cp` when any path is under `/mnt/shared` — use `rsync` instead. The virtio-fs / sdcardfs bridge can crash the VM mid-copy (observed: zero-length destinations, hang, full app reset).
- `~/.claude/` is **not** bulk-snapshotted. An earlier version of this repo snapshotted the whole tree (sessions, file-history, auto-memory, projects/, telemetry, daemon state…) and a restore corrupted the VM badly enough to require a full Debian reinstall. Today, only `~/.claude/CLAUDE.md` and `~/.claude/.credentials.json` round-trip via `SNAPSHOT_FILES`, and plugins/skills reinstall from manifests on each rebuild. The shipped CLAUDE.md tells the Claude Code agent to track durable project state in project-local `CLAUDE.md` files instead of relying on the auto-memory system at `~/.claude/projects/<wd>/memory/` (which is wiped on rebuild). `/resume` does not survive a rebuild.
- `~/.claude.json` (the top-level Claude config file) corrupted repeatedly when snapshotted whole. Today we only snapshot the auth subset (`oauthAccount`, `userID`, `hasCompletedOnboarding` — see `CLAUDE_JSON_AUTH_KEYS` in `bin/lib.sh`) and merge it into the live file on restore via `jq`, so `claude` stays logged in but the corruption-prone bulk file is never replaced. MCP server registrations and other fields are not carried; re-add them after a rebuild if needed.
- Concurrent shells fight for `.bash_history`. The `history -a` PROMPT_COMMAND in `.bashrc` mitigates loss, but two simultaneous edits can still interleave.
- `devenv init` never overwrites real files. It backs them up to `~/.devenv-backup/<timestamp>/`, so it's safe to re-run.
