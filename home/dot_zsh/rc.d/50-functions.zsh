# Open a dev environment (Claude + lazygit + nvim) for a directory.
#   -z         persistent, detachable Zellij session (default; reattach by
#              re-running `dev` or `zellij attach`)
#   -k         kitty native splits — no detach/persistence, but keeps the kitty
#              graphics protocol (inline images in the Claude pane)
#   -n <name>  override the title / Claude session name
dev() {
  local name_override="" backend="zellij"
  while [[ "$1" == -* ]]; do
    case "$1" in
      -n)
        [[ -z "$2" || "$2" == -* ]] && { echo "dev: -n requires a name" >&2; return 1; }
        name_override="$2"; shift 2 ;;
      -z) backend="zellij"; shift ;;
      -k) backend="kitty"; shift ;;
      --) shift; break ;;
      *) echo "dev: unknown option $1" >&2; return 1 ;;
    esac
  done
  local dir="${1:-.}"
  dir="$(cd "$dir" && pwd)"
  local name="${name_override:-$(basename "$dir")}"
  if [[ "$backend" == zellij ]]; then
    kitty --title "$name" --directory "$dir" -e dev-zellij -n "$name" -d "$dir" -- -n "$name" &>/dev/null & disown
  else
    kitty --title "$name" --directory "$dir" --session <(dev-kitty-session -n "$name") &>/dev/null & disown
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
