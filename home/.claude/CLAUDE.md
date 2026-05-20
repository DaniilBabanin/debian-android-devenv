# Project progress tracking — what survives a VM rebuild

This Debian VM is rebuilt frequently. The persistence layer at
`/mnt/shared/debian-env/` (or wherever you cloned this repo) carries only this
`CLAUDE.md` and `~/.claude/.credentials.json` across full rebuilds. Everything
else under `~/.claude/` is wiped on each rebuild:

- `~/.claude/projects/<wd>/sessions/` — **`/resume` does not survive a rebuild.**
- `~/.claude/projects/<wd>/memory/` — the auto-memory system is ephemeral here.
- `~/.claude/projects/<wd>/file-history/`, `tasks/`, `daemon/`, `shell-snapshots/`.
- `~/.claude/settings.json`, `~/.claude.json`, MCP server registrations.

This is a deliberate tradeoff: a bulk `~/.claude/` restore once corrupted the
VM, so persistence inside it is now opt-in per-file (see `SNAPSHOT_FILES` in
`bin/lib.sh`). Plan your work accordingly:

- **Write durable project context into a project-local `CLAUDE.md`** at the
  working-directory root, not into the auto-memory system. The auto-memory
  files at `~/.claude/projects/<wd>/memory/` will disappear on the next VM
  rebuild — anything you'd want to recall belongs in the project's `CLAUDE.md`
  instead.
- For any non-trivial multi-session task, keep a short progress section in the
  project's `CLAUDE.md`: what's done, what's in flight, the next concrete step,
  and any decisions or constraints that aren't obvious from the code. Update
  as work progresses, not only at session end.
- Treat `/resume` as best-effort within a single VM lifetime only. Don't rely
  on it for cross-rebuild continuity.

# Missing tools

If you wish a CLI tool were installed while working on a task, append it to
`/mnt/shared/debian-env/tool-wishlist.md` (one line:
`- tool — what it does / task that needed it / YYYY-MM-DD`).
The user reviews this list before updating the dev env.

# Copying files on /mnt/shared

`/mnt/shared` is a virtio-fs / sdcardfs bridge to Android storage. **Never use
`cp` when any path is under `/mnt/shared`** — not the source, not the
destination, not even copying between two `/mnt/shared` paths. `cp` against
this mount can crash the VM mid-write (observed: zero-length destinations,
process hang, full app reset). Use rsync instead:

```bash
rsync -a --info=progress2 SRC DST
```

Add `--no-links` when copying onto the shared mount (it can't create symlinks).
Plain `cp` is fine only when source **and** destination are entirely outside
`/mnt/shared` (e.g. both inside `$HOME` on the VM's ext4).

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
