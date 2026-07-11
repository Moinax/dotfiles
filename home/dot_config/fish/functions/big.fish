# Top 10 biggest entries (incl. hidden) in CWD
function big
    # Unmatched globs expand to nothing inside `set` (no zsh (D) qualifier needed)
    set -l entries .* *
    test (count $entries) -gt 0; or return
    sudo du -sh -- $entries | sort -rh | head -n 10
end
