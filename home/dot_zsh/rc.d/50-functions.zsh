# Open a dev environment (AI agent + lazygit + nvim) for a directory.
#   -z         persistent, detachable Zellij session (default; reattach by
#              re-running `dev` or `zellij attach`)
#   -k         kitty native splits — no detach/persistence, but keeps the kitty
#              graphics protocol (inline images in the agent pane)
#   -n <name>  override the title / agent session name
#   -p <prov>  AI agent provider: claude (default), codex, opencode
dev() {
  local name_override="" backend="zellij" provider="claude"
  while [[ "$1" == -* ]]; do
    case "$1" in
      -n)
        [[ -z "$2" || "$2" == -* ]] && { echo "dev: -n requires a name" >&2; return 1; }
        name_override="$2"; shift 2 ;;
      -p)
        [[ "$2" != (claude|codex|opencode) ]] && { echo "dev: -p must be claude|codex|opencode" >&2; return 1; }
        provider="$2"; shift 2 ;;
      -z) backend="zellij"; shift ;;
      -k) backend="kitty"; shift ;;
      --) shift; break ;;
      *) echo "dev: unknown option $1" >&2; return 1 ;;
    esac
  done
  local dir="${1:-.}"
  dir="$(cd "$dir" && pwd)"
  local name="${name_override:-$(basename "$dir")}"
  # Window title carries the provider for non-claude so same-project windows
  # (and their distinct zellij sessions) are tellable apart.
  local title="$name"; [[ "$provider" != claude ]] && title="$name ($provider)"
  if [[ "$backend" == zellij ]]; then
    kitty --title "$title" --directory "$dir" -e dev-zellij -n "$name" -d "$dir" -p "$provider" &>/dev/null & disown
  else
    kitty --title "$title" --directory "$dir" --session <(dev-kitty-session -p "$provider" -n "$name") &>/dev/null & disown
  fi
}
# Back-compat alias: `kdev` keeps its original kitty-splits behavior (k = kitty).
alias kdev='dev -k'

# yazi wrapper that cd's the parent shell to yazi's exit cwd
y() {
  local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
  yazi "$@" --cwd-file="$tmp"
  IFS= read -r -d '' cwd < "$tmp"
  [ -n "$cwd" ] && [ "$cwd" != "$PWD" ] && builtin cd -- "$cwd"
  rm -f -- "$tmp"
}
