#!/usr/bin/env bash
# Python toolchain: system python3 + pipx + uv.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../bin/lib.sh"

PKGS=(python3 python3-pip python3-venv pipx)

missing=()
for p in "${PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ]; then
    log "python: apt install ${missing[*]}"
    maybe_sudo apt-get update
    maybe_sudo apt-get install -y --no-install-recommends "${missing[@]}"
else
    ok "python: apt packages already present"
fi

# Make sure pipx user bin is on PATH for current shell (and persisted via .bashrc).
pipx ensurepath >/dev/null 2>&1 || true
export PATH="$HOME/.local/bin:$PATH"

if ! pipx list 2>/dev/null | grep -q '^package uv '; then
    log "python: pipx install uv"
    pipx install uv
else
    ok "python: uv already installed via pipx"
fi

ok "python: $(python3 --version)  uv: $(uv --version 2>/dev/null || echo missing)"
