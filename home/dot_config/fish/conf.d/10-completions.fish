# Completions. Fish ships git (and most everything else) natively — no
# git-completion.bash / compinit equivalent needed.
if status is-interactive
    # fnm
    command -q fnm; and fnm completions --shell fish | source
end
