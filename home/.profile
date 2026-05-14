# ~/.profile — sh-compatible, loaded by login shells (bash, sh, dash).

# set PATH so it includes user's private bin if it exists
[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"
export PATH

# devenv root (useful for scripts that want to find it without resolving symlinks)
[ -d /mnt/shared/debian-env ] && export DEVENV_ROOT=/mnt/shared/debian-env
