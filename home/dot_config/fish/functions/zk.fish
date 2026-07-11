# zk — stop a running zellij session (name arg, or fuzzy-pick via television)
function zk
    set -l name $argv[1]
    test -z "$name"; and set name (_zj_pick kill)
    test -n "$name"; and zellij kill-session $name
end
