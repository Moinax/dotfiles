# Fish port of the zsh setup in ~/.zsh/rc.d/ — conf.d/*.fish fragments are
# auto-sourced (in lexicographic order) before this file; each owns a single
# concern. Functions live in functions/ and autoload on first use.

# Welcome banner: only on a top-level shell in a real terminal emulator.
# Embedded terminals (VS Code, Cursor, WebStorm, Claude Code, nvim :term) inherit
# TERM=xterm-256color from their parent and won't match this allowlist.
if status is-interactive; and command -q fastfetch; and test "$SHLVL" = 1
    switch "$TERM"
        case xterm-kitty 'alacritty*' wezterm 'foot*' xterm-ghostty
            fastfetch
    end
end

# Local overrides not managed by chezmoi (counterpart of ~/.zshrc.local).
test -f ~/.config/fish/local.fish; and source ~/.config/fish/local.fish
