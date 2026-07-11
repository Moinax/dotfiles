# yazi wrapper that cd's the parent shell to yazi's exit cwd
function y
    set -l tmp (mktemp -t yazi-cwd.XXXXXX)
    yazi $argv --cwd-file=$tmp
    if read -z cwd <$tmp; and test -n "$cwd"; and test "$cwd" != "$PWD"
        builtin cd -- $cwd
    end
    rm -f -- $tmp
end
