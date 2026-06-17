# WorkTrunk shell integration (cd's parent shell on `wt switch`)
if command -v wt &> /dev/null; then
  eval "$(command wt config shell init zsh)"
fi

# Create/switch worktree, then launch a kitty dev environment in it.
# Stays a function (not a script) because `wt switch` requires shell integration.
#   -n <name>  override the kitty title / agent session name
#   -s         auto-run `/start <branch>` in the agent pane on launch (claude only)
#   -p <prov>  AI agent provider: claude (default), codex, opencode
#   -z         persistent, detachable Zellij session (default)
#   -k         kitty native splits (no persistence; keeps the image protocol)
wtstart() {
  local name_override=""
  local send_start=false
  local backend="zellij"
  local provider="claude"
  while [[ "$1" == -* ]]; do
    case "$1" in
      -n)
        [[ -z "$2" || "$2" == -* ]] && { echo "wtstart: -n requires a name" >&2; return 1; }
        name_override="$2"; shift 2 ;;
      -p)
        [[ "$2" != (claude|codex|opencode) ]] && { echo "wtstart: -p must be claude|codex|opencode" >&2; return 1; }
        provider="$2"; shift 2 ;;
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

  # A non-empty prompt is auto-submitted to the agent on launch; -s uses that to
  # make Claude run `/start <branch>`. `/start` is a Claude command and only
  # claude auto-submits from the CLI, so -s is gated to the claude provider.
  local prompt=""
  if $send_start; then
    if [[ "$provider" != claude ]]; then
      echo "wtstart: -s only applies to claude (/start is a Claude command); skipping" >&2
    elif [[ -n "$resolved_branch" ]]; then
      prompt="/start $resolved_branch"
    else
      echo "wtstart: -s set but no branch resolved; skipping /start" >&2
    fi
  fi

  local title="$name"; [[ "$provider" != claude ]] && title="$name ($provider)"
  if [[ "$backend" == zellij ]]; then
    kitty --title "$title" --directory "$dir" -e dev-zellij -n "$name" -d "$dir" -p "$provider" -- "$prompt" &>/dev/null & disown
  else
    kitty --title "$title" --directory "$dir" --session <(dev-kitty-session -p "$provider" -n "$name" -- "$prompt") &>/dev/null & disown
  fi

  builtin cd -- "$orig_dir"
}

alias wts=wtstart
alias wtc=wtclean      # standalone script in ~/.local/bin
alias wtu=wtupdate     # standalone script in ~/.local/bin
