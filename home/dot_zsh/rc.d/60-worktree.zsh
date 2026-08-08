# WorkTrunk shell integration (cd's parent shell on `wt switch`)
if command -v wt &> /dev/null; then
  eval "$(command wt config shell init zsh)"
fi

# Create/switch worktree, then launch a kitty dev environment in it.
# Only the `wt switch` calls live here (they need shell integration); the
# launch half is wtstart-launch, shared with the fish function.
#   -n <name>  append " - <name>" after the "<project>.<branch>" title
#   -s         auto-run `/start <branch>` in the agent pane on launch (claude only)
#   -p <prov>  AI agent provider: claude (default), codex, opencode
wtstart() {
  local -a pass=()
  while [[ "$1" == -* ]]; do
    case "$1" in
      -n)
        [[ -z "$2" || "$2" == -* ]] && { echo "wtstart: -n requires a name" >&2; return 1; }
        pass+=(-n "$2"); shift 2 ;;
      -p) pass+=(-p "$2"); shift 2 ;;
      -s) pass+=(-s); shift ;;
      --) shift; break ;;
      *) echo "wtstart: unknown option $1" >&2; return 1 ;;
    esac
  done

  local branch="$1"
  local orig_dir="$PWD"

  if [[ -z "$branch" ]]; then
    wt switch || return 1
    [[ "$PWD" == "$orig_dir" ]] && return 0
  else
    # wt-switch-args (shared with fish and the vicinae worktree picker) fetches origin when the
    # branch is unknown and prints --create only when it is genuinely new, so
    # a remote-only branch checks out tracking origin/<branch>.
    local -a switch_args=($(wt-switch-args "$branch"))
    wt switch "${switch_args[@]}" "$branch" || {
      echo "error: failed to switch to worktree for '$branch'" >&2
      return 1
    }
  fi

  wtstart-launch -d "$PWD" -b "$branch" "${pass[@]}"

  builtin cd -- "$orig_dir"
}

alias wts=wtstart
alias wtc=wtclean      # standalone script in ~/.local/bin
alias wtu=wtupdate     # standalone script in ~/.local/bin
alias dcl=dev-clean    # clean merged worktrees across all dev projects
