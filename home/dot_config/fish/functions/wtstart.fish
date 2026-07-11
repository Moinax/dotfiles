# Create/switch worktree, then launch a kitty dev environment in it.
# Stays a function (not a script) because `wt switch` requires shell integration.
#   -n <name>  append " - <name>" after the "<project>.<branch>" title
#   -s         auto-run `/start <branch>` in the agent pane on launch (claude only)
#   -p <prov>  AI agent provider: claude (default), codex, opencode
function wtstart
    argparse --stop-nonopt 'n=' 's' 'p=' -- $argv
    or return 1

    set -l provider claude
    if set -q _flag_p
        if not contains -- $_flag_p claude codex opencode
            echo "wtstart: -p must be claude|codex|opencode" >&2
            return 1
        end
        set provider $_flag_p
    end

    set -l branch $argv[1]
    set -l is_new false
    set -l orig_dir $PWD

    # Project name = main repo dir name (resolved before switching; works from the
    # repo root or an existing worktree). Used to prefix the title as "<project>.<branch>".
    set -l project
    set -l git_common (git rev-parse --git-common-dir 2>/dev/null)
    if test -n "$git_common"
        set project (path basename (path resolve (path dirname $git_common)))
    else
        set project (path basename $orig_dir)
    end

    if test -z "$branch"
        wt switch; or return 1
        test "$PWD" = "$orig_dir"; and return 0
    else
        if git show-ref --verify --quiet refs/heads/$branch
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
            set is_new true
        end

        # Copy gitignored files (e.g. .env.development.local) for new worktrees only
        if test $is_new = true
            wt step copy-ignored
        end
    end

    set -l resolved_branch $branch
    test -z "$resolved_branch"; and set resolved_branch (git branch --show-current)
    # Always lead with "<project>.<branch>"; -n appends " - <name>" after it.
    set -l name "$project.$resolved_branch"
    if set -q _flag_n; and test -n "$_flag_n"
        set name "$name - $_flag_n"
    end
    set -l dir $PWD

    # A non-empty prompt is auto-submitted to the agent on launch; -s uses that to
    # make Claude run `/start <branch>`. `/start` is a Claude command and only
    # claude auto-submits from the CLI, so -s is gated to the claude provider.
    set -l prompt ""
    if set -q _flag_s
        if test $provider != claude
            echo "wtstart: -s only applies to claude (/start is a Claude command); skipping" >&2
        else if test -n "$resolved_branch"
            set prompt "/start $resolved_branch"
        else
            echo "wtstart: -s set but no branch resolved; skipping /start" >&2
        end
    end

    # No --title: dev-zellij pins the window title itself (so it stays renameable
    # on the fly via Ctrl+Alt+R). See the note in dev-zellij.
    kitty --directory $dir -e dev-zellij -n $name -d $dir -p $provider -- "$prompt" >/dev/null 2>&1 &
    disown

    builtin cd -- $orig_dir
end
