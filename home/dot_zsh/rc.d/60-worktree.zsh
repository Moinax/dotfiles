# WorkTrunk shell integration (cd's parent shell on `wt switch`)
if command -v wt &> /dev/null; then
  eval "$(command wt config shell init zsh)"
fi

# Create/switch worktree, then open it as a tab in the zellij session.
# Only the `wt switch` call lives here — it needs shell integration; `dev` owns
# the tab, its name and the terminal window. The -n/-p/-s options went with the
# agent panes: /start is a Claude command with no pane to type into now, and a
# checkout has exactly one tab, so a name suffix has nothing to tell apart.
wtstart() {
  local branch="$1"
  local orig_dir="$PWD"

  if [[ -z "$branch" ]]; then
    wt switch || return 1
    [[ "$PWD" == "$orig_dir" ]] && return 0
  else
    # wt-switch-args (shared with the vicinae worktree picker) fetches origin
    # when the branch is unknown and prints --create only when it is genuinely
    # new, so a remote-only branch checks out tracking origin/<branch>.
    local -a switch_args=($(wt-switch-args "$branch"))
    wt switch "${switch_args[@]}" "$branch" || {
      echo "error: failed to switch to worktree for '$branch'" >&2
      return 1
    }
  fi

  dev "$PWD"

  builtin cd -- "$orig_dir"
}

alias wts=wtstart
alias wtc='wt step prune'  # remove worktrees merged into the default branch
alias wtu=wtupdate     # standalone script in ~/.local/bin
alias dcl=dev-clean    # clean merged worktrees across all dev projects
