# ~/.bash_profile — load .profile then .bashrc on login shells.
[ -f "$HOME/.profile" ] && . "$HOME/.profile"
[ -f "$HOME/.bashrc" ]  && . "$HOME/.bashrc"
