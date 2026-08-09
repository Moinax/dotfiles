# History
HISTFILE=~/.histfile
HISTSIZE=1000
SAVEHIST=1000

# Type a directory name to cd into it
setopt autocd

# Emacs keymap (use `bindkey -v` for vi mode)
bindkey -e

# Word-jump and edit bindings
bindkey '^[[1;5C' forward-word        # Ctrl+Right
bindkey '^[[1;5D' backward-word       # Ctrl+Left
bindkey "\e[3~"   delete-char         # Delete
bindkey '\e[H'    beginning-of-line   # Home
bindkey '\e[F'    end-of-line         # End

# Editor
# VISUAL is the desktop editor only. Kate over Cursor: Cursor 2.x made the agent
# panel the default surface, which is the wrong thing to land in when you just
# want to read a file. Kate is Qt6 (no Electron), reuses the KDE libs already
# installed, has the LSP client on by default, and previews Markdown via
# markdownpart. Everything else stays on nvim — including git, which is pinned
# through core.editor in dot_gitconfig.tmpl and never consults VISUAL.
export EDITOR="nvim"
export VISUAL="kate"
export SUDO_EDITOR="nvim"
