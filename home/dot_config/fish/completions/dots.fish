# Completion for `dots` (the dotfiles manager).
#
# Candidates come from `dots __complete`, which parses the tools' own help
# output — adding a command to dots or one of its sub-tools makes it
# completable here with no change to this file.

function __dots_token_count
    count (commandline -opc)
end

function __dots_subcommand
    set -l tokens (commandline -opc)
    test (count $tokens) -ge 2; and echo $tokens[2]
end

# No bare file completion: the first two tokens are always command names.
complete -c dots -f

complete -c dots -n 'test (__dots_token_count) -eq 1' -a '(dots __complete)'
complete -c dots -n 'test (__dots_token_count) -eq 2' \
    -a '(dots __complete (__dots_subcommand))'

# Past the subcommand it's options and paths — hand it back to file completion.
complete -c dots -n 'test (__dots_token_count) -ge 3' -F
