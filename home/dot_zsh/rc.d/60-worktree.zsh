# WorkTrunk shell integration (cd's parent shell on `wt switch`)
if command -v wt &> /dev/null; then
  eval "$(command wt config shell init zsh)"
fi

# Create/switch worktree, then launch a kitty dev environment in it.
# Stays a function (not a script) because `wt switch` requires shell integration.
#   -n <name>  override the kitty title / Claude session name
#   -s         auto-run `/start <branch>` in the Claude pane on launch
#   -z         persistent, detachable Zellij session (default)
#   -k         kitty native splits (no persistence; keeps the image protocol)
wtstart() {
  local name_override=""
  local send_start=false
  local backend="zellij"
  while [[ "$1" == -* ]]; do
    case "$1" in
      -n)
        [[ -z "$2" || "$2" == -* ]] && { echo "wtstart: -n requires a name" >&2; return 1; }
        name_override="$2"; shift 2 ;;
      -s) send_start=true; shift ;;
      -z) backend="zellij"; shift ;;
      -k) backend="kitty"; shift ;;
      --) shift; break ;;
      *) echo "wtstart: unknown option $1" >&2; return 1 ;;
    esac
  done

  local branch="$1"
  local is_new=false
  local orig_dir="$PWD"

  if [[ -z "$branch" ]]; then
    wt switch || return 1
    [[ "$PWD" == "$orig_dir" ]] && return 0
  else
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      wt switch "$branch" || {
        echo "error: failed to switch to worktree for '$branch'" >&2
        return 1
      }
    else
      wt switch --create "$branch" || {
        echo "error: failed to create worktree for '$branch'" >&2
        return 1
      }
      is_new=true
    fi

    # Copy gitignored files (e.g. .env.development.local) for new worktrees only
    if $is_new; then
      wt step copy-ignored
    fi
  fi

  local resolved_branch="${branch:-$(git branch --show-current)}"
  local name="${name_override:-$resolved_branch}"
  local dir="$PWD"

  # A bare positional arg becomes claude's auto-submitted initial prompt;
  # -s uses that to make Claude run `/start <branch>` on launch.
  local -a claude_args=(-n "$name")
  if $send_start; then
    if [[ -n "$resolved_branch" ]]; then
      claude_args+=("/start $resolved_branch")
    else
      echo "wtstart: -s set but no branch resolved; skipping /start" >&2
    fi
  fi

  if [[ "$backend" == zellij ]]; then
    kitty --title "$name" --directory "$dir" -e dev-zellij -n "$name" -d "$dir" -- "${claude_args[@]}" &>/dev/null & disown
  else
    kitty --title "$name" --directory "$dir" --session <(dev-kitty-session "${claude_args[@]}") &>/dev/null & disown
  fi

  builtin cd -- "$orig_dir"
}

alias wts=wtstart
alias wtc=wtclean      # standalone script in ~/.local/bin
alias wtu=wtupdate     # standalone script in ~/.local/bin
