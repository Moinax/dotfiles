# WorkTrunk shell integration (cd's parent shell on `wt switch`)
if command -v wt &> /dev/null; then
  eval "$(command wt config shell init zsh)"
fi

# Create/switch worktree, then launch a kitty dev environment in it.
# Stays a function (not a script) because `wt switch` requires shell integration.
#   -n <name>  append " - <name>" after the "<project>.<branch>" title
#   -s         auto-run `/start <branch>` in the agent pane on launch (claude only)
#   -p <prov>  AI agent provider: claude (default), codex, opencode
wtstart() {
  local name_override=""
  local send_start=false
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
      --) shift; break ;;
      *) echo "wtstart: unknown option $1" >&2; return 1 ;;
    esac
  done

  local branch="$1"
  local is_new=false
  local orig_dir="$PWD"

  # Project name = main repo dir name (resolved before switching; works from the
  # repo root or an existing worktree). Used to prefix the title as "<project>.<branch>".
  local git_common project
  git_common="$(git rev-parse --git-common-dir 2>/dev/null)"
  if [[ -n "$git_common" ]]; then
    project="$(basename "$(cd "$(dirname "$git_common")" && pwd)")"
  else
    project="$(basename "$orig_dir")"
  fi

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
  # Always lead with "<project>.<branch>"; -n appends " - <name>" after it.
  local name="$project.$resolved_branch"
  [[ -n "$name_override" ]] && name="$name - $name_override"
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

  # No --title: dev-zellij pins the window title itself (so it stays renameable
  # on the fly via Ctrl+Alt+R). See the note in dev-zellij.
  kitty --directory "$dir" -e dev-zellij -n "$name" -d "$dir" -p "$provider" -- "$prompt" &>/dev/null & disown

  builtin cd -- "$orig_dir"
}

alias wts=wtstart
alias wtc=wtclean      # standalone script in ~/.local/bin
alias wtu=wtupdate     # standalone script in ~/.local/bin
