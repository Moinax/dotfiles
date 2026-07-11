# zoxide: smart cd
if status is-interactive; and command -q zoxide
    zoxide init fish --cmd cd | source
end
