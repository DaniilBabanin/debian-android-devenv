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
```

## What persists

Anything you'd otherwise have to rewrite from memory after a reinstall:

| Path | Purpose |
|---|---|
| `home/.bashrc`, `.bash_profile`, `.profile` | shell config |
| `home/.bash_history` | full history; flushed every command |
| `home/.inputrc` | readline tweaks |
| `home/.gitconfig` | git identity + aliases |
| `home/.npmrc` | npm config |
| `home/.config/` | XDG configs (nvim, etc.) |
| `home/.claude/` | Claude Code creds, MCP servers, settings |
| `archives/ssh.tar.gz` | `~/.ssh` — keys, `known_hosts`, `authorized_keys` (tar preserves 700/600 perms across FUSE) |

What doesn't persist, because reinstalling is cheap and the modules re-establish it:

- apt packages (re-installed by `install-base`)
- `~/.nvm/` and Node binaries (re-installed by `install-node`)
- pipx envs (re-installed by `install-python`)
- the Claude binary itself (re-installed by `install-claude`, though creds in `~/.claude/` persist)

## Telling Claude about the installed tools

If you use Claude Code in this environment, paste the block below into your
user-level `~/.claude/CLAUDE.md`. It tells the agent what's on PATH so it
reaches for the right tool instead of falling back to whatever it knows from
training, and points it at this repo's wishlist file for things it wishes were
installed.

````markdown
# Missing tools

If you wish a CLI tool were installed while working on a task, append it to
`/mnt/shared/debian-env/tool-wishlist.md` (one line:
`- tool — what it does / task that needed it / YYYY-MM-DD`).
The user reviews this list before updating the dev env.

# Available CLI tools

## Search & inspection
- `rg` (ripgrep) — default for code search; faster than `grep -r`, respects `.gitignore`
- `fd` — fast `find` replacement, `.gitignore`-aware (symlinked from `fdfind`); prefer over `find` for name-based lookups
- `ast-grep` — structural AST-based code search; use for "find all callers of X with arg shape Y" patterns that regex handles poorly. Always invoke as `ast-grep`; the upstream `sg` alias collides with Debian's `/usr/bin/sg` (newgrp)
- `ctags` (universal-ctags) — generate a `tags` symbol index (`ctags -R`) for fast jump-to-def via `rg '^Symbol\b' tags`
- `tokei` — fast per-language LOC / file count for a quick repo overview
- `jq` — JSON parsing/filtering (APIs, configs, `package.json`)
- `yq` — YAML querying (wraps `jq`); targeted reads of GH Actions / k8s / compose / pre-commit configs without Read-ing whole files
- `dasel` — multi-format (TOML/JSON/YAML/XML) querying; reach for `pyproject.toml`, `Cargo.toml`, `wrangler.toml`
- `sqlite3` — query `.db`/`.sqlite` files directly instead of writing throwaway Python
- `bat` — syntax-highlighted file display (symlinked from `batcat`)
- `tree` — directory overview (`tree -L 2 -I node_modules`)
- `fzf` — interactive fuzzy finder; useful in pipes
- `file` — identify unknown file types before opening

## Network & transfer
- `curl` / `wget` — HTTP fetches and downloads
- `gh` — GitHub CLI; PR/issue/run/release ops, repo queries via `gh api`
- `rsync` — incremental/remote copy; better than `cp -r` for large or remote trees
- `ssh` / `scp` / `ssh-keygen` — remote shells, keys, secure copy

## Archives & crypto
- `zip` / `unzip`, `tar`, `gzip` — archives
- `gpg` — signature verification, signing, encryption

## Build & binaries
- `git`, `make`, `gcc`/`g++` (build-essential) — version control and native compilation

## Lint, diff & secret scan (verify before declaring done)
- `shellcheck` — lint shell scripts before executing; catches quoting/glob errors at author time, not runtime
- `ruff` — fast Python linter/formatter; verify Python diffs are clean before claiming done
- `gitleaks` — scan for committed secrets; run before staging files that may contain credentials (`gitleaks detect --no-banner`)
- `difft` (difftastic) — structural/syntax-aware diff; collapses formatting-only churn when reviewing changes

## Debugging & perf
- `strace` — trace syscalls of hanging or opaque processes; evidence over speculation during debugging
- `hyperfine` — command-line benchmarking with warmups and statistical output

## Scripting languages
- `python3`, `perl` — available for ad-hoc scripting / one-liners

## Process & session
- `tmux` — long-lived sessions, split panes (for Claude background work prefer `run_in_background`)
- `expect` — drive interactive prompts non-interactively; avoids "please run this yourself" handoffs when a CLI insists on a TTY
````

The wishlist path assumes you cloned this repo to `/mnt/shared/debian-env`;
update the path in the pasted block if you cloned somewhere else.

## Adding a module

Drop `modules/install-<name>.sh` into `modules/`. The dispatcher picks it up automatically.

Module contract:

- Source `../bin/lib.sh` at the top.
- Detect already-installed state and exit 0 fast.
- Use `maybe_sudo` for root-required commands.
- Use `have <cmd>` to test for tools.
- The dispatcher writes the success sentinel; your module just needs to exit 0.

## Adding a dotfile to persist

1. Put the file under `home/` (or a subdirectory).
2. Add its top-level name to the `TOPLEVEL` array in `bin/init.sh`.
3. Run `devenv init` to link it.

Whole directories link as one symlink, so anything underneath is automatic.

## Risks and known limits

- `/mnt/shared/` on Android is typically FUSE/sdcardfs and may not honor unix mode bits. That's why `~/.ssh` lives in `archives/ssh.tar.gz` (tar bakes 700/600 into the archive metadata) instead of `home/.ssh/` (which would lose perms on the FUSE round-trip). `~/.gnupg` would need the same treatment; see `ARCHIVE_DIRS` in `bin/lib.sh` to add more.
- Concurrent shells fight for `.bash_history`. The `history -a` PROMPT_COMMAND in `.bashrc` mitigates loss, but two simultaneous edits can still interleave.
- `devenv init` never overwrites real files. It backs them up to `~/.devenv-backup/<timestamp>/`, so it's safe to re-run.
