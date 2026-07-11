# Editor
set -gx EDITOR nvim
set -gx VISUAL cursor
set -gx SUDO_EDITOR nvim

# No default greeting — the fastfetch banner in config.fish replaces it.
set -g fish_greeting

# Autosuggestions and syntax highlighting are built into fish; only the
# suggestion color needs matching to the zsh setup (#696969).
set -g fish_color_autosuggestion 696969

# No keybinding fixes needed: fish binds Ctrl+arrows / Home / End / Delete
# out of the box, and `cd`-by-typing-a-directory (zsh autocd) is native too.
