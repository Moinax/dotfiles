# Create/switch worktree, then launch a kitty dev environment in it.
# Only the `wt switch` calls live here (they need shell integration); the
# launch half is wtstart-launch, shared with the zsh function.
#   -n <name>  append " - <name>" after the "<project>.<branch>" title
#   -s         auto-run `/start <branch>` in the agent pane on launch (claude/claudex)
#   -p <prov>  AI agent provider: claude (default), claudex, codex, opencode
function wtstart
    argparse --stop-nonopt 'n=' 's' 'p=' -- $argv
    or return 1

    set -l branch $argv[1]
    set -l orig_dir $PWD
    set -l pass

    if test -z "$branch"
        wt switch; or return 1
        test "$PWD" = "$orig_dir"; and return 0
    else if git show-ref --verify --quiet refs/heads/$branch
        wt switch $branch
        or begin
            echo "error: failed to switch to worktree for '$branch'" >&2
            return 1
        end
    else
        wt switch --create $branch
        or begin
            echo "error: failed to create worktree for '$branch'" >&2
            return 1
        end
        set -a pass --new
    end

    set -q _flag_n; and test -n "$_flag_n"; and set -a pass -n $_flag_n
    set -q _flag_s; and set -a pass -s
    set -q _flag_p; and set -a pass -p $_flag_p
    wtstart-launch -d $PWD -b "$branch" $pass

    builtin cd -- $orig_dir
end
