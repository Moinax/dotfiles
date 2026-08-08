# Create/switch worktree, then launch a kitty dev environment in it.
# Only the `wt switch` calls live here (they need shell integration); the
# launch half is wtstart-launch, shared with the zsh function.
#   -n <name>  append " - <name>" after the "<project>.<branch>" title
#   -s         auto-run `/start <branch>` in the agent pane on launch (claude only)
#   -p <prov>  AI agent provider: claude (default), codex, opencode
function wtstart
    argparse --stop-nonopt 'n=' 's' 'p=' -- $argv
    or return 1

    set -l branch $argv[1]
    set -l orig_dir $PWD
    set -l pass

    if test -z "$branch"
        wt switch; or return 1
        test "$PWD" = "$orig_dir"; and return 0
    else
        # wt-switch-args (shared with zsh and the vicinae worktree picker) fetches origin when the
        # branch is unknown and prints --create only when it is genuinely new,
        # so a remote-only branch checks out tracking origin/<branch>.
        set -l switch_args (wt-switch-args $branch)
        wt switch $switch_args $branch
        or begin
            echo "error: failed to switch to worktree for '$branch'" >&2
            return 1
        end
    end

    set -q _flag_n; and test -n "$_flag_n"; and set -a pass -n $_flag_n
    set -q _flag_s; and set -a pass -s
    set -q _flag_p; and set -a pass -p $_flag_p
    wtstart-launch -d $PWD -b "$branch" $pass

    builtin cd -- $orig_dir
end
