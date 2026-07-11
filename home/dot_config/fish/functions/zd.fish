# zd — drop an exited zellij session to force a clean rebuild
# (name arg, or fuzzy-pick via television)
function zd
    set -l name $argv[1]
    test -z "$name"; and set name (_zj_pick delete)
    test -n "$name"; and zellij delete-session $name
end
