# devenv — persistent Debian dev environment

Survives full reinstalls of the Debian-on-Android emulator by keeping dotfiles and an install dispatcher on the Android-side shared mount (`/mnt/shared/debian-env/`).

> **Termux variant:** the AVF terminal VM proved unstable, so the same devenv
> also runs inside proot-distro Debian on Termux — see [`termux/README.md`](termux/README.md).
> The shared-storage repo is bound to `/mnt/shared` in the guest, so everything
> below applies unchanged; only the `termux/` shim is Termux-specific.

## After a fresh Debian install

```bash
bash /mnt/shared/debian-env/bootstrap.sh 
```

```bash
ulimit -s unlimited && CLAUDE_CODE_NO_FLICKER=1 CLAUDE_CODE_DISABLE_MOUSE=1 claude --permission-mode auto
```

```bash
ulimit -s unlimited &&
CLAUDE_CODE_NO_FLICKER=1 CLAUDE_CODE_DISABLE_MOUSE=1 claude
```

```bash
port CLAUDE_CODE_SUBAGENT_MODEL="claude-opus-4-7"
```

That:

1. Symlinks `~/.bashrc`, `~/.bash_history`, `~/.claude/`, etc. into `$HOME`.
2. Puts `devenv` on PATH at `~/.local/bin/devenv`.
3. Runs all install modules (`base`, `node`, `python`, `claude`).

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
devenv probe -- npm test          # measure VM degradation signals around a workload
devenv watch --tail               # show recent degradation episodes caught by the watcher
```

## What persists

Anything you'd otherwise have to rewrite from memory after a reinstall:

| Path | Mechanism | Purpose |
|---|---|---|
| `home/.bashrc`, `.bash_profile`, `.profile` | symlink | shell config |
| `home/.inputrc` | symlink | readline tweaks |
| `home/.gitconfig` | symlink | git identity + aliases |
| `home/.npmrc` | symlink | npm config |
| `state/home/.config/` | snapshot dir | XDG configs (nvim, etc.) |
| `state/home/.bash_history` | snapshot file | full history; flushed every command |
| `state/files/.claude/CLAUDE.md` | snapshot file | Claude Code global guidance (seeded from `home/.claude/CLAUDE.md` on first run) |
| `state/files/.claude/.credentials.json` | snapshot file | Claude Code auth token (chmod 600 on restore) |
| `archives/ssh.tar.gz` | tar archive | `~/.ssh` — keys, `known_hosts`, `authorized_keys` (tar preserves 700/600 perms across FUSE) |
| `metrics/probe.jsonl`, `metrics/episodes.jsonl` | append-only log | VM health / degradation signals, trended **across** rebuilds (see Health & degradation monitoring) |

What does **not** persist (by design — reinstall is cheap, modules re-establish):

- apt packages (re-installed by `install-base`)
- `~/.nvm/` and Node binaries (re-installed by `install-node`)
- pipx envs (re-installed by `install-python`)
- the Claude binary itself (re-installed by `install-claude`)
- Claude Code plugins, marketplaces, and user-installed skills (re-installed by `install-claude-plugins` from manifests in `modules/claude-{marketplaces,plugins,skills}.txt`)
- code-server, autossh, and the VS Code launcher scripts `code-local` / `pc-tunnel` / `pc-setup-code-web` (re-installed by the opt-in `install-vscode` — VS Code in the phone browser for local files at `localhost:8080` and PC files at `localhost:8001` through the cloudflared ssh tunnel; see header of `modules/install-vscode.sh`)
- the rest of `~/.claude/` — sessions, `projects/`, auto-memory, `file-history`, `settings.json`, `~/.claude.json`, telemetry. **`/resume` does not survive a VM rebuild.** A bulk `~/.claude/` snapshot once corrupted the VM, so persistence inside that directory is now opt-in per-file via `SNAPSHOT_FILES` in `bin/lib.sh`. The seeded `~/.claude/CLAUDE.md` instructs Claude to track durable project state in project-local `CLAUDE.md` files instead of relying on the auto-memory system.

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

There is no shutdown-time snapshot: capturing state at an arbitrary (possibly
broken) moment is exactly what the versioned, boot-only model avoids.

## Health & degradation monitoring

The VM tends to degrade only under heavy work (node/python scripts, multi-agent
runs), not at idle. Two collectors capture the kernel's own degradation signals
— PSI stall (`/proc/pressure/{cpu,memory,io}`), `MemAvailable` low-water, zram
use, OOM/hung-task events, shared-mount latency — and log them to `metrics/` on
the shared mount so the data **trends across rebuilds**. The goal is to harden
from measured failure, not gut feeling. Full design: [`docs/harden-spec.md`](docs/harden-spec.md).

**`devenv probe`** — deliberate, point-in-time. Appends one JSON line to
`metrics/probe.jsonl`. `bootstrap.sh` runs it once per boot (`--label
boot-baseline`) — but a fresh VM always looks fine, so baselines answer "did
this boot start clean", not "what degrades under load".

```bash
devenv probe                      # one-shot snapshot + human summary
devenv probe --watch 60           # sample a 60s window (peak / low-water / PSI deltas)
devenv probe -- cargo build       # run a workload, measure until it exits
devenv probe --tail 20            # show recent samples
```

**`devenv watch`** — automatic, the load-time companion. A systemd `--user`
service (installed + enabled by `install-watch`, in the default bootstrap set)
that is near-silent when calm — every 15s it reads only the PSI files, no
`ps`/`dmesg`, **no log write** — and records **one coalesced episode** (with the
culprit process tree: who's eating RSS/CPU) to `metrics/episodes.jsonl` *only*
when stall / low-mem / OOM trips. So the log grows with how often the VM
actually struggles, and each row tells you the *why*.

```bash
systemctl --user status devenv-watch.service     # is the watcher running?
devenv watch --tail 20                            # recent degradation episodes
jq -r '.top_procs[0].comm' metrics/episodes.jsonl | sort | uniq -c | sort -rn   # recurring culprit
jq 'select(.psi_us.mem_full>0 or .oom_events>0)' metrics/episodes.jsonl          # any real memory pressure?
```

Thresholds and cadence are env-tunable (`DEVENV_WATCH_*`, see the unit and
`docs/harden-spec.md`). No hardening levers (earlyoom, tmpfs, swappiness) are
enabled yet — the spec gates each one on a signal the episode log has to show
first. As of the baselines, only IO stall (shared mount) ever fires; memory is
clean.

## Adding a module

Drop `modules/install-<name>.sh` into `modules/`. The dispatcher picks it up automatically.

Module contract:

- Source `../bin/lib.sh` at the top.
- Detect already-installed state and exit 0 fast.
- Use `maybe_sudo` for root-required commands.
- Use `have <cmd>` to test for tools.
- The dispatcher writes the success sentinel — your module just needs to exit 0.

## Adding a dotfile to persist

Pick the right mechanism for the file:

- **Read-mostly dotfile** (`.bashrc`, `.gitconfig`, …) — put under `home/`, add to `LINK_DOTFILES` in `bin/lib.sh`, `devenv init` to symlink. Whole directories are linked as one symlink.
- **Stateful directory** (XDG dirs, SQLite-backed apps) — add to `STATEFUL_DIRS` in `bin/lib.sh`. Managed by `devenv snapshot` / `devenv restore` via rsync. **Do not** add anything that bulk-mishaves (large opaque dir, frequent churn, daemons writing while snapshot runs) — see the `~/.claude/` incident.
- **Single file inside a directory we deliberately don't bulk-snapshot** (e.g. `~/.claude/CLAUDE.md`) — add the HOME-relative path to `SNAPSHOT_FILES` in `bin/lib.sh`. Snapshot/restore handle one file at a time. A matching file under `home/<path>` acts as a first-run seed template.
- **Anything needing strict mode bits across FUSE/sdcardfs** (`~/.ssh`, `~/.gnupg`) — add to `ARCHIVE_DIRS` in `bin/lib.sh`. Stored as tar.gz so perms survive.

## Adding a Claude Code plugin or skill

Plugins and skills aren't persisted directly — they're reinstalled from manifests on each rebuild via `modules/install-claude-plugins.sh`:

- Marketplace: append a source to `modules/claude-marketplaces.txt`
- Plugin: append `<plugin>@<marketplace>` to `modules/claude-plugins.txt`
- Skill: append a `<git-url> [name]` line to `modules/claude-skills.txt`

`devenv install claude-plugins` (re)runs the install. Idempotent — already-installed entries are skipped.

## Risks / known limits

- `/mnt/shared/` on Android is typically FUSE/sdcardfs and may not honor unix mode bits. That's why `~/.ssh` lives in `archives/ssh.tar.gz` (tar bakes 700/600 into the archive metadata) instead of `home/.ssh/` (which would lose perms on the FUSE round-trip). `~/.gnupg` would need the same treatment — see `ARCHIVE_DIRS` in `bin/lib.sh` to add more.
- Concurrent shells fight for `.bash_history`. The `history -a` PROMPT_COMMAND in `.bashrc` mitigates loss but two simultaneous edits can interleave.
- `devenv init` never overwrites real files — it backs them up to `~/.devenv-backup/<timestamp>/`. Safe to re-run.
