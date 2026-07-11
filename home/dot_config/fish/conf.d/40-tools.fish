if status is-interactive
    # starship prompt
    if command -q starship
        starship init fish | source
    end

    # television: CTRL+T file picker, CTRL+R history search.
    # No override needed here (unlike zsh): fish's tv_smart_autocomplete always
    # launches tv, so an empty prompt never falls back to shell completion.
    if command -q tv
        tv init fish | source
    end
end

# ssh-agent: adopt OpenSSH's systemd `ssh-agent.socket` user unit (Arch).
# It lives in $XDG_RUNTIME_DIR (tmpfs), so it can't go stale across a reboot.
# environment.d exports SSH_AUTH_SOCK session-wide too; setting it here also
# covers shells started before that import. (The keychain fallback for
# non-Arch hosts lives only in the zsh config — this repo targets CachyOS.)
if test -S "$XDG_RUNTIME_DIR/ssh-agent.socket"
    set -gx SSH_AUTH_SOCK $XDG_RUNTIME_DIR/ssh-agent.socket
end
