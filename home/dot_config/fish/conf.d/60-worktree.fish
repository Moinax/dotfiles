# WorkTrunk shell integration (cd's parent shell on `wt switch`).
# wtstart itself is an autoloaded function in ../functions/.
if status is-interactive; and command -q wt
    command wt config shell init fish | source
end

alias wts wtstart
alias wtc wtclean # standalone script in ~/.local/bin
alias wtu wtupdate # standalone script in ~/.local/bin
