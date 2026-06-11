#!/usr/bin/env bash
# install-claude-plugins.sh — install Claude Code marketplaces, plugins, and
# skills from declarative manifests. Idempotent enough to re-run; failures on
# individual entries warn but don't abort the module (so one removed upstream
# plugin doesn't block the rest).
#
# Why not snapshot ~/.claude/plugins and ~/.claude/skills directly?
# A bulk-snapshot of ~/.claude/ once corrupted the VM, so persistence at the
# /mnt/shared boundary is now opt-in per file (see SNAPSHOT_FILES). Plugins
# and skills are reproducible artifacts — manifests + reinstall is safer and
# cheaper than carrying ~14M of mostly-static files across FUSE.
#
# Manifests live next to this script. One entry per line, '#' for comments,
# blank lines ignored:
#   modules/claude-marketplaces.txt    <source>             e.g. anthropics/claude-plugins-official
#   modules/claude-plugins.txt         <plugin>@<market>    e.g. superpowers@claude-plugins-official
#   modules/claude-skills.txt          <git-url> [name]     e.g. https://github.com/blader/humanizer.git

set -euo pipefail
__self="${BASH_SOURCE[0]}"
while [ -L "$__self" ]; do __self="$(readlink -f "$__self")"; done
# shellcheck disable=SC1091
source "$(dirname "$__self")/../bin/lib.sh"

if ! have claude; then
    warn "claude CLI missing — run \`devenv install claude\` first"
    exit 0
fi

manifest_dir="$DEVENV_MODULES"

# Read a manifest: strip '#' comments and blank lines.
_read_manifest() {
    local f="$1"
    [ -f "$f" ] || return 0
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$f"
}

# ---- marketplaces --------------------------------------------------------
step "marketplaces"
existing_markets="$(claude plugin marketplace list 2>/dev/null || true)"
while IFS= read -r src; do
    [ -z "$src" ] && continue
    short="${src##*/}"
    if grep -qE "(^|[[:space:]])${short}([[:space:]]|$)" <<<"$existing_markets"; then
        ok "marketplace already present: $src"
        continue
    fi
    log "adding marketplace: $src"
    if claude plugin marketplace add "$src"; then
        ok "added marketplace: $src"
    else
        warn "marketplace add failed: $src"
    fi
done < <(_read_manifest "$manifest_dir/claude-marketplaces.txt")

# ---- plugins -------------------------------------------------------------
step "plugins"
existing_plugins="$(claude plugin list 2>/dev/null || true)"
while IFS= read -r spec; do
    [ -z "$spec" ] && continue
    plugin_name="${spec%@*}"
    if grep -qE "(^|[[:space:]])${plugin_name}([[:space:]@]|$)" <<<"$existing_plugins"; then
        ok "plugin already installed: $spec"
        continue
    fi
    log "installing plugin: $spec"
    if claude plugin install "$spec"; then
        ok "installed plugin: $spec"
    else
        warn "plugin install failed: $spec"
    fi
done < <(_read_manifest "$manifest_dir/claude-plugins.txt")

# ---- patch: strip node-dependent caveman hooks when node is absent -------
# caveman's plugin.json registers SessionStart + UserPromptSubmit hooks that
# shell out to `node`. With the node module not installed (it's opt-in) those
# fire on every prompt as `node: not found`. The hooks only maintain a mode
# flag and power /caveman-stats — caveman's behavior itself comes from the
# skill + CLAUDE.md, so dropping them is harmless. Reinstalling caveman from
# the marketplace restores the hooks, hence we re-strip here on every run.
# Guarded on node-absence: if you later `devenv install node`, the hooks stay
# and work instead of being stripped. Idempotent (no-op once .hooks is gone).
if ! have node && have jq; then
    step "patch caveman hooks (node absent)"
    while IFS= read -r pj; do
        jq -e 'has("hooks")' "$pj" >/dev/null 2>&1 || continue
        tmp="$pj.devenv-patch.$$"
        if jq 'del(.hooks)' "$pj" > "$tmp" && mv -- "$tmp" "$pj"; then
            ok "stripped node hooks: $pj"
        else
            rm -f -- "$tmp"; warn "failed to patch $pj"
        fi
    done < <(find "$HOME/.claude/plugins" -path '*caveman*/.claude-plugin/plugin.json' 2>/dev/null)
fi

# ---- skills (user-installed via git clone) -------------------------------
step "skills"
mkdir -p "$HOME/.claude/skills"
while IFS= read -r line; do
    [ -z "$line" ] && continue
    # split on whitespace into url + optional name
    # shellcheck disable=SC2086
    set -- $line
    url="$1"; name="${2:-}"
    if [ -z "$name" ]; then
        bn="$(basename "$url")"
        name="${bn%.git}"
    fi
    dst="$HOME/.claude/skills/$name"
    if [ -d "$dst/.git" ]; then
        ok "skill already cloned: $name"
        continue
    fi
    if [ -e "$dst" ]; then
        warn "skill path exists but is not a git checkout: $dst (leaving alone)"
        continue
    fi
    log "cloning skill: $url -> $dst"
    if git clone --depth 1 "$url" "$dst"; then
        ok "cloned skill: $name"
    else
        warn "skill clone failed: $url"
    fi
done < <(_read_manifest "$manifest_dir/claude-skills.txt")

ok "claude-plugins module done"
