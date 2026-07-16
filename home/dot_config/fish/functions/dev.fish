# Open a persistent, detachable Zellij dev environment (AI agent + lazygit +
# nvim) for a directory. Reattach by re-running `dev` or `zellij attach`.
#   -n <name>  append " - <name>" after the directory name in the title
#   -p <prov>  AI agent provider: claude (default), codex, opencode
function dev
    argparse --stop-nonopt 'n=' 'p=' -- $argv
    or return 1

    set -l provider claude
    if set -q _flag_p
        if not contains -- $_flag_p claude codex opencode
            echo "dev: -p must be claude|codex|opencode" >&2
            return 1
        end
        set provider $_flag_p
    end

    set -l dir .
    set -q argv[1]; and set dir $argv[1]
    if not test -d "$dir"
        echo "dev: no such directory: $dir" >&2
        return 1
    end
    set dir (path resolve -- $dir)

    # Always lead with the directory name; -n appends " - <name>" after it.
    set -l name (path basename $dir)
    if set -q _flag_n; and test -n "$_flag_n"
        set name "$name - $_flag_n"
    end

    # dev-mux dispatches to the configured multiplexer (chezmoi use_herdr /
    # DEV_MUX) and owns window spawning per backend.
    dev-mux -n $name -d $dir -p $provider >/dev/null 2>&1 &
    disown
end
