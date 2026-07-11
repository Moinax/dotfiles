# za — reattach to an agent session (resurrects exited ones).
# Pass a name to act directly, or omit it to fuzzy-pick via television.
function za
    if set -q ZELLIJ
        echo "Already inside a Zellij session — use Ctrl+o w to switch." >&2
        return 1
    end
    set -l name $argv[1]
    test -z "$name"; and set name (_zj_pick attach)
    test -n "$name"; and zellij attach $name
end
