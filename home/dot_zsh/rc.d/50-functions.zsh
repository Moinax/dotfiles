# Open a persistent, detachable Zellij dev environment (AI agent + lazygit +
# nvim) for a directory. Reattach by re-running `dev` or `zellij attach`.
#   -n <name>  append " - <name>" after the directory name in the title
#   -p <prov>  AI agent provider: claude (default), codex, opencode
dev() {
  local name_override="" provider="claude"
  while [[ "$1" == -* ]]; do
    case "$1" in
      -n)
        [[ -z "$2" || "$2" == -* ]] && { echo "dev: -n requires a name" >&2; return 1; }
        name_override="$2"; shift 2 ;;
      -p)
        [[ "$2" != (claude|codex|opencode) ]] && { echo "dev: -p must be claude|codex|opencode" >&2; return 1; }
        provider="$2"; shift 2 ;;
      --) shift; break ;;
      *) echo "dev: unknown option $1" >&2; return 1 ;;
    esac
  done
  local dir="${1:-.}"
  dir="$(cd "$dir" && pwd)"
  # Always lead with the directory name; -n appends " - <name>" after it.
  local name="$(basename "$dir")"
  [[ -n "$name_override" ]] && name="$name - $name_override"
  # dev-mux dispatches to the configured multiplexer (chezmoi use_herdr /
  # DEV_MUX) and owns window spawning per backend.
  dev-mux -n "$name" -d "$dir" -p "$provider" &>/dev/null & disown
}

# yazi wrapper that cd's the parent shell to yazi's exit cwd
y() {
  local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
  yazi "$@" --cwd-file="$tmp"
  IFS= read -r -d '' cwd < "$tmp"
  [ -n "$cwd" ] && [ "$cwd" != "$PWD" ] && builtin cd -- "$cwd"
  rm -f -- "$tmp"
}
