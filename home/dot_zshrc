# Lines configured by zsh-newuser-install
HISTFILE=~/.histfile
HISTSIZE=1000
SAVEHIST=1000
# Allow to type a directory name without prefixing it with "cd"
setopt autocd
# Set the shell to "emacs" mode. You can use -v instead to use the "ui" mode
bindkey -e
# End of lines configured by zsh-newuser-install

# Bind Ctrl+Right to move forward a word
bindkey '^[[1;5C' forward-word
# Bind Ctrl+Left to move backward a word
bindkey '^[[1;5D' backward-word
# Bind Delete to delete a word
bindkey "\e[3~" delete-char
# Home key binding: Move cursor to the beginning of the line
bindkey '\e[H' beginning-of-line
# End key binding: Move cursor to the end of the line
bindkey '\e[F' end-of-line

# The following lines were added by compinstall

zstyle ':completion:*' completer _complete _ignored
zstyle ':completion:*:default' menu select=0
zstyle :compinstall filename "$HOME/.zshrc"

# Load Git completion
zstyle ':completion:*:*:git:*' script ~/.zsh/git-completion.bash
fpath=(~/.zsh $fpath)

autoload -Uz compinit
compinit
# End of lines added by compinstall


# Add zsh auto suggestions
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#696969"

# Add zsh syntax highlighting
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# Show fastfetch at startup
if [ "$TERM_PROGRAM" != "vscode" ]; then 
		fastfetch
fi

# Editor
export EDITOR="nvim"
export VISUAL="cursor"

# Replace cd by zoxide
alias cd="z"
# Replace ls by eza
alias ls="eza"
alias lsa="ls -la"
# Add shortcuts to nvim
alias vim="nvim"
alias vi="nvim"
alias v="nvim"
# Add shortcuts to lazygit
alias lg="lazygit"
# Add shortcuts to lazydocker
alias ld="lazydocker"
# Add shortucts to find the biggest files in the current directory (even hidden files)
alias big="sudo du -sh *(D) | sort -rh | head -n 10"

# Volta
export VOLTA_HOME="$HOME/.volta"
export PATH="$VOLTA_HOME/bin:$PATH"
source ~/completion-for-pnpm.bash

# Turso
export PATH="$HOME/.turso:$PATH"

# Pnpm
export PNPM_HOME="$HOME/.local/share/pnpm"
   case ":$PATH:" in
     *":$PNPM_HOME:"*) ;;
     *) export PATH="$PNPM_HOME:$PATH" ;;
   esac

# Lazy docker
export PATH="$HOME/.local/bin:$PATH"


# Set up fzf key bindings and fuzzy completion
source <(fzf --zsh)

# Store the ssh key for further use in git
eval "$(keychain --eval id_ed25519)"

function y() {
	local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
	yazi "$@" --cwd-file="$tmp"
	IFS= read -r -d '' cwd < "$tmp"
	[ -n "$cwd" ] && [ "$cwd" != "$PWD" ] && builtin cd -- "$cwd"
	rm -f -- "$tmp"
}

# Add different rofi scripts in the path @see https://github.com/adi1090x/rofi
export PATH=$HOME/.config/rofi/scripts:$PATH

# Initialiaze starhsip
eval "$(starship init zsh)"

# Initialize zoxide
eval "$(zoxide init zsh)"
export PATH="$HOME/.local/bin:$PATH"
