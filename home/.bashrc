# ~/.bashrc — persisted via devenv (/mnt/shared/debian-env/home/.bashrc)

# If not running interactively, don't do anything.
case $- in *i*) ;; *) return ;; esac

# --- history (persisted across Debian reinstalls) ---
HISTCONTROL=ignoredups:erasedups
HISTSIZE=100000
HISTFILESIZE=200000
HISTTIMEFORMAT='%F %T  '
shopt -s histappend cmdhist
# Flush each command to disk immediately so multiple shells share history
# AND a crash doesn't lose the session.
PROMPT_COMMAND="history -a; ${PROMPT_COMMAND:-}"

# --- PATH ---
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH

# --- nvm (loaded only if installed) ---
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# --- prompt ---
if [ -n "${debian_chroot:-}" ]; then PS1_CHROOT="(${debian_chroot}) "; else PS1_CHROOT=""; fi
PS1="${PS1_CHROOT}\[\033[01;32m\]\u@\h\[\033[0m\]:\[\033[01;34m\]\w\[\033[0m\]\$ "

# --- aliases ---
alias ls='ls --color=auto'
alias ll='ls -lah'
alias la='ls -A'
alias grep='grep --color=auto'
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate -20'

# bat is named batcat on Debian; init.sh / base module symlinks it
have() { command -v "$1" >/dev/null 2>&1; }
if have batcat && ! have bat; then alias bat='batcat'; fi
if have rg; then alias grep-fast='rg'; fi
unset -f have

# --- color ---
export LESS='-R'
export EDITOR="${EDITOR:-nvim}"
export VISUAL="${VISUAL:-$EDITOR}"

# --- completion ---
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi

# --- user overrides (per-machine, not persisted) ---
[ -f "$HOME/.bashrc.local" ] && . "$HOME/.bashrc.local"
