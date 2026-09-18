# starship prompt
if command -v starship &> /dev/null; then
  eval "$(starship init zsh)"
fi

# television: CTRL+T file picker, CTRL+R history search
if command -v tv &> /dev/null; then
  eval "$(tv init zsh)"

  # Override smart autocomplete so an empty prompt launches `tv files`
  # instead of zsh's expand-or-complete (which would offer "5500 possibilities").
  _tv_smart_autocomplete() {
    _disable_bracketed_paste
    local tokens prefix lbuf
    setopt localoptions noshwordsplit noksh_arrays noposixbuiltins

    tokens=(${(z)LBUFFER})
    if [ ${#tokens} -lt 1 ]; then
      zle -I
      local output
      output=$(tv files --no-status-bar --inline < /dev/tty)
      if [ -n "$output" ]; then
        LBUFFER="${(q)output} "
      fi
      zle reset-prompt
      _enable_bracketed_paste
      return
    fi

    [[ ${LBUFFER[-1]} == ' ' ]] && tokens+=("")
    if [[ ${LBUFFER} = *"${tokens[-2]-}${tokens[-1]}" ]]; then
      tokens[-2]="${tokens[-2]-}${tokens[-1]}"
      tokens=(${tokens[0,-2]})
    fi

    lbuf=$LBUFFER
    prefix=${tokens[-1]}
    [ -n "${tokens[-1]}" ] && lbuf=${lbuf:0:-${#tokens[-1]}}
    __tv_path_completion "$prefix" "$lbuf"
    _enable_bracketed_paste
  }
fi

# direnv: per-directory env. socle's .envrc enters its Nix flake shell through
# this hook; without it the .envrc is inert unless run via `direnv exec`.
if command -v direnv &> /dev/null; then
  eval "$(direnv hook zsh)"
fi

# ssh-agent. Where OpenSSH's systemd `ssh-agent.socket` user unit is active
# (Arch), adopt its socket: it lives in $XDG_RUNTIME_DIR (tmpfs), so it can't
# go stale across a reboot. environment.d exports SSH_AUTH_SOCK session-wide
# too; setting it here also covers shells started before that import.
if [[ -S "${XDG_RUNTIME_DIR}/ssh-agent.socket" ]]; then
  export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR}/ssh-agent.socket"

# Otherwise fall back to keychain (Debian/Ubuntu). keychain reuses a cached
# agent from ~/.keychain/<host>-*, but since OpenSSH 10.x moved the agent
# socket into persistent $HOME that cache can point at a dead agent that
# survived a reboot -- so probe before trusting it. `ssh-add -l` exit 2 means
# "could not connect" (dead); a reachable agent (exit 0/1) is left alone so
# agents shared with other shells aren't disturbed.
elif command -v keychain &> /dev/null; then
  _agent_dead() { ssh-add -l &>/dev/null; [[ $? -eq 2 ]]; }
  # inherited env: drop a dead socket so keychain falls back to its cache
  if [[ -n "$SSH_AUTH_SOCK" ]] && _agent_dead; then
    unset SSH_AUTH_SOCK SSH_AGENT_PID
  fi
  # keychain's pidfile: delete a dead cache so keychain spawns a fresh agent
  _kc_base="$HOME/.keychain/${HOST}"
  if [[ -f "$_kc_base-sh" ]] && ( source "$_kc_base-sh" && _agent_dead ); then
    rm -f "$_kc_base"-{sh,csh,fish}
  fi
  unfunction _agent_dead; unset _kc_base
  eval "$(keychain --eval --quiet id_ed25519)"
fi
