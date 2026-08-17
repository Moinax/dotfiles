#!/usr/bin/env bash
# Build (and rebuild) the DigitalOcean host that runs T3 Code headless.
#
# The host is deliberately disposable — see docs/adr/0002. No unique *data*
# lives on it, so this script is what brings it back. Every phase is idempotent:
# re-running it on a live host is the repair path, not a reinstall.
#
# The command list lives in usage() below, and only there — a second copy in
# this header is what CLAUDE.md warns about, and it had already drifted once.
#
# A rebuild, with no browser at all:
#
#   dots droplet destroy && dots droplet create && dots droplet setup \
#     && dots droplet restore
#
# That leaves the wizard three stages instead of eleven — repos, pairing,
# firewall — and none of them opens a browser. It is NOT "no wizard": the scoped
# repo restore is stage 6, driven by an archive on the desktop, and STATE_PATHS
# deliberately carries no repos.
#
# `firewall` is deliberately not chained on either: restore only *queues* the
# Tailscale identity swap. cmd_firewall refuses while one is pending, so this is
# a note about ordering rather than the only thing standing between you and a
# locked-out host.
#
# The manual steps this cannot do — Tailscale auth, registering the host's SSH
# key on GitHub and Forgejo, the sops key, the `claude`/`codex` logins and the
# o27 MCP servers — are walked by tools/droplet-wizard.sh. That last one was
# listed here as "Linear OAuth" for a while with no stage behind it, which is
# worse than an omission: it reads as covered.
#
# Self-contained on purpose: the remote half is scp'd to a bare Ubuntu box that
# has none of this repo, so it must not source install/lib/common.sh.
set -euo pipefail

DROPLET_NAME="${DROPLET_NAME:-t3code-host}"
REGION="${REGION:-ams3}"
SIZE="${SIZE:-s-4vcpu-8gb-amd}"
IMAGE="${IMAGE:-ubuntu-24-04-x64}"
REMOTE_USER="${REMOTE_USER:-jerome}"
FIREWALL_NAME="${FIREWALL_NAME:-$DROPLET_NAME-deny-all}"
SWAP_GB="${SWAP_GB:-8}"

# The desktop's PUBLIC key, authorized for login. The host's own identity is a
# separate keypair generated on the host itself (phase: sshkey) — this repo's
# rule is that ~/.ssh never leaves the desktop, and a public key is not ~/.ssh.
DO_SSH_KEY_NAME="${DO_SSH_KEY_NAME:-moinax-desktop}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; NC=$'\033[0m'
info()    { printf '%b%-9s%b %s\n' "$BLUE"   "[INFO]"    "$NC" "$1"; }
ok()      { printf '%b%-9s%b %s\n' "$GREEN"  "[SUCCESS]" "$NC" "$1"; }
warn()    { printf '%b%-9s%b %s\n' "$YELLOW" "[WARNING]" "$NC" "$1"; }
err()     { printf '%b%-9s%b %s\n' "$RED"    "[ERROR]"   "$NC" "$1" >&2; }
header()  { printf '\n%b══ %s%b\n' "$BLUE" "$1" "$NC"; }

# Used by both halves, so it lives above the local/remote split rather than
# under the "Remote half" banner, which would make that banner a lie.
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'EOF'
Usage: dots droplet <command>       (or tools/provision-droplet.sh <command>)

Commands:
  create      Create the droplet (cloud-init: login user + your desktop key)
  setup       Provision or repair it — idempotent, this is the recovery path
  pair        Mint a pairing code for one more device (single-use, ~5 min)
  firewall    Close the public IP; only once Tailscale is up
  status      What exists, what is reachable, what is missing
  target      Print user@address for the host (public IP, else tailnet)
  snapshot    Save the credentials the wizard produced (age-encrypted, ~20 KB)
  restore     Push a snapshot back onto a freshly set-up host
  destroy     Delete the droplet and its firewall
  wizard      The half that needs you: browser logins, key registration

`remote` and `report` also exist; both run ON the host and are called by setup
and status. Running them from the desktop does nothing useful.
EOF
}

# ── Local half ───────────────────────────────────────────────────────────────

# One lookup shape, six callers: `doctl compute <resource> list` keyed by name.
# Written out per call site it drifted immediately — the ssh-key copy asked for
# ID,Name and flipped the awk fields to compensate, so the one that read
# differently from its neighbours did so for no reason at all.
do_lookup() {
    doctl compute "$1" list --format Name,"$2" --no-header 2>/dev/null \
        | awk -v n="$3" '$1 == n { print $2; exit }'
}

droplet_ip()  { do_lookup droplet PublicIPv4 "$DROPLET_NAME"; }
droplet_id()  { do_lookup droplet ID         "$DROPLET_NAME"; }
firewall_id() { do_lookup firewall ID        "$FIREWALL_NAME"; }

# Where to reach the host, as a user@address for ssh and scp.
#
# The public IP is the answer right up until `firewall` closes it — and this
# script is the declared recovery path (docs/adr/0002), so it has to keep
# working afterwards or the ADR is false. The desktop is on the same tailnet, so
# its own tailscaled answers first-hand; nothing cached, nothing to drift.
host_target() {
    local ip ts
    ip=$(droplet_ip)
    if [ -n "$ip" ] && ssh -o BatchMode=yes -o ConnectTimeout=5 \
           -o StrictHostKeyChecking=accept-new "$REMOTE_USER@$ip" true 2>/dev/null; then
        printf '%s@%s\n' "$REMOTE_USER" "$ip"
        return 0
    fi
    ts=$(tailscale status --json 2>/dev/null \
         | jq -r --arg n "$DROPLET_NAME" \
             'first((.Peer // {} | .[]) | select(.HostName == $n) | .TailscaleIPs[0]) // empty' 2>/dev/null)
    [ -n "$ts" ] || return 1
    printf '%s@%s\n' "$REMOTE_USER" "$ts"
}

require_doctl() {
    command -v doctl >/dev/null || { err "doctl is not installed"; exit 1; }
    doctl account get >/dev/null 2>&1 || { err "doctl is not authenticated"; exit 1; }
}

# Same shape as require_doctl, for the other precondition four commands share.
# Called as `target=$(require_target)`: the exit only ends the substitution
# subshell, and `set -e` on the failed assignment is what stops the caller —
# the message still reaches your terminal, since stderr is not captured.
require_target() {
    host_target || { err "Cannot reach $DROPLET_NAME on its public IP or the tailnet"; exit 1; }
}

# cloud-init does exactly two things: create the login user and authorize the
# desktop key. Everything else is the remote half, because everything else needs
# to be re-runnable — and cloud-init only ever runs once.
cloud_init_user_data() {
    local pubkey="$1"
    cat <<EOF
#cloud-config
users:
  - name: $REMOTE_USER
    groups: [sudo]
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - $pubkey
package_update: true
EOF
}

cmd_create() {
    require_doctl

    local existing
    existing=$(droplet_ip)
    if [ -n "$existing" ]; then
        ok "$DROPLET_NAME already exists at $existing"
        return 0
    fi

    local key_id pubkey
    key_id=$(do_lookup ssh-key ID "$DO_SSH_KEY_NAME")
    [ -n "$key_id" ] || { err "No DO ssh key named '$DO_SSH_KEY_NAME'"; exit 1; }

    pubkey=$(cat "$HOME/.ssh/id_ed25519.pub" 2>/dev/null) \
        || { err "No ~/.ssh/id_ed25519.pub to authorize"; exit 1; }

    local user_data
    user_data=$(mktemp)
    trap 'rm -f "$user_data"' RETURN
    cloud_init_user_data "$pubkey" > "$user_data"

    header "Creating $DROPLET_NAME ($SIZE, $REGION, $IMAGE)"
    doctl compute droplet create "$DROPLET_NAME" \
        --region "$REGION" --size "$SIZE" --image "$IMAGE" \
        --ssh-keys "$key_id" --user-data-file "$user_data" \
        --wait --format Name,PublicIPv4,Status

    local ip
    ip=$(droplet_ip)
    ok "Droplet up at $ip"

    info "Waiting for SSH..."
    for _ in $(seq 60); do
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
               -o BatchMode=yes "$REMOTE_USER@$ip" true 2>/dev/null; then
            ok "SSH is up as $REMOTE_USER"
            return 0
        fi
        sleep 5
    done
    err "SSH never came up — check the DO console"
    return 1
}

cmd_setup() {
    local target
    target=$(require_target)

    header "Provisioning $target"
    scp -q -o StrictHostKeyChecking=accept-new "$0" "$target:/tmp/provision-droplet.sh"
    # -t so apt and the installers get a tty; without one, some of them buffer
    # everything to the end and a 10-minute phase looks like a hang. It also
    # claims stdin, which is why this stays scp-then-ssh rather than `bash -s`.
    ssh -t -o StrictHostKeyChecking=accept-new "$target" \
        "bash /tmp/provision-droplet.sh remote"
}

# Deny-all inbound. Runs last, and only once Tailscale is up: applied before
# that, it takes SSH away with nothing to replace it, and the only way back in
# is the DO web console.
cmd_firewall() {
    require_doctl
    local id ip
    ip=$(droplet_ip)
    [ -n "$ip" ] || { err "No droplet named $DROPLET_NAME"; exit 1; }

    id=$(droplet_id)

    # Two conditions, one probe. The second is the one that bites after a
    # `restore`: that command only QUEUES the identity swap in a transient unit,
    # so a plain "is Tailscale up?" answers yes about the daemon that is seconds
    # from being replaced — and closing the public IP against an identity nothing
    # has proved leaves the DO web console as the only way back. The signal needs
    # no new state: tailscaled.state.new exists exactly between restore's
    # `install` and the unit's `mv`, so its presence means pending or failed.
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$(require_target)" \
             '! sudo -n test -e /var/lib/tailscale/tailscaled.state.new \
              && tailscale status --json >/dev/null 2>&1 && tailscale ip -4' 2>/dev/null; then
        err "Tailscale is not up on the host, or an identity swap is still pending"
        info "After a restore, wait for the host to answer on the tailnet"
        info "Otherwise run the wizard's Tailscale step, then come back to this"
        return 1
    fi

    local existing
    existing=$(firewall_id)
    if [ -n "$existing" ]; then
        ok "Firewall $FIREWALL_NAME already exists"
        doctl compute firewall add-droplets "$existing" --droplet-ids "$id" >/dev/null
        ok "Droplet attached"
        return 0
    fi

    header "Creating deny-all firewall"
    # No inbound rules at all = nothing reaches the public IP. Outbound stays
    # wide open: the host has to fetch packages and reach the tailnet's DERP
    # relays, and restricting it buys nothing on a box with no inbound surface.
    doctl compute firewall create \
        --name "$FIREWALL_NAME" \
        --droplet-ids "$id" \
        --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0 protocol:icmp,address:0.0.0.0/0,address:::/0" \
        --format Name,Status
    ok "Public IP is now closed; reach the host over the tailnet"
}

# Pairing is a recurring need, not a provisioning step: a token is per-device
# and lives about five minutes, so adding a phone or a second laptop months
# later has nothing to do with the ten-stage wizard. It lives here because this
# is where host_target already is, and the wizard's stage 9 is now a pointer at
# it rather than the only way to reach it.
cmd_pair() {
    local target
    target=$(require_target)
    header "Pairing a device with $DROPLET_NAME"
    info "Each code is single-use — run this again for the next device."
    ssh -t -o StrictHostKeyChecking=accept-new "$target" \
        'export PATH="$HOME/.local/bin:$HOME/.local/share/fnm/aliases/default/bin:$PATH"; t3 pair --tailscale'
}

# ── Credential snapshot ──────────────────────────────────────────────────────
#
# What a rebuilt host cannot re-derive on its own. Every entry is the residue of
# a wizard stage, named by title rather than number — the numbers are only
# `# ── N ──` banners in droplet-wizard.sh and are the most drift-prone thing
# there is to point at. In order: "GitHub — authorize the host's own key" and
# its Forgejo twin, "sops — convey the o27 decryption key", "Forge tokens", the
# "Claude Code"/"Codex" sign-ins, and "Pair your desktop and your phone".
# 20 KB compressed, measured — which is why this needs no storage of its own.
#
# `~/.t3/userdata/state.sqlite` is deliberately absent. It holds sessions and
# history — that is data, and docs/adr/0002 says no unique *data* lives on this
# host. A credential snapshot that quietly grew into a data backup would reverse
# that decision by accident. It also cannot be copied honestly while t3code is
# running, since its WAL is open.
#
# The one knowing exception is `.claude.json`, which mixes `oauthAccount` with a
# `projects` history: the login can live in either that file or
# `.claude/.credentials.json`, which is why the wizard's own Claude stage tests
# both. Stated here because a policy with a silent exception is how the next
# exception gets added without an argument.
STATE_PATHS=(
    .ssh/id_ed25519 .ssh/id_ed25519.pub
    .ssh/o27_socle_sops .ssh/o27_socle_sops.pub
    .config/gh/hosts.yml .config/tea/config.yml
    .claude/.credentials.json .claude.json
    .codex/auth.json
    .t3/userdata/environment-id .t3/userdata/secrets
)

# backup-projects.sh owns this directory; it is re-derived rather than sourced
# here for the same reason sync-machine.sh re-derives it — that script runs a
# command on source. Named once so the archive path and the commit hint below
# cannot drift into disagreeing about where the file went.
STATE_REPO="$HOME/Backups/projects-backup"

# Next to the project backup when that repo is present, so `dots backup create`
# carries the archive off-site with its own.
state_archive() {
    local dir="$STATE_REPO"
    [ -d "$dir/.git" ] || dir="$HOME/Backups"
    printf '%s\n' "$dir/droplet-state.tar.gz.age"
}

cmd_snapshot() {
    have age || { err "age is not installed"; exit 1; }
    local target out
    # Same optional positional as cmd_restore, so the pair reads identically and
    # neither needs an environment variable to say the one thing they both take.
    out="${1:-$(state_archive)}"
    target=$(require_target)
    mkdir -p "$(dirname "$out")"

    header "Snapshotting the credentials of $DROPLET_NAME"
    info "age asks for a passphrase — use the one your project backup uses."

    # Encrypted on the desktop, never on the host: the plaintext tar exists only
    # inside the pipe. Written to .tmp first so an interrupted run cannot leave a
    # truncated archive sitting where a restore would later trust it.
    #
    # Script on stdin, paths as arguments — the shape cmd_status already uses.
    # Written the other way round, interpolated into a double-quoted command
    # string, it needed a dozen hand-escaped \$ and \", where a single missed one
    # expands on the desktop instead of the host and does so silently. The
    # heredoc also holds ssh's stdin, so ssh cannot read the terminal and race
    # `age -p` for the passphrase you are typing.
    #
    # The remote `trap` matters for the same reason the encryption does: the
    # staging copy is plaintext keys and tokens. Abort the passphrase prompt and
    # `set -e` would otherwise skip the cleanup and leave them in /tmp.
    #
    # `tar -v` (archive on stdout, so the file list goes to stderr) is what states
    # what was captured rather than asking you to take its word. It is NOT free,
    # which is what the first version got wrong: ssh's stderr is the terminal, so
    # those 25 lines land while `age -p` is still waiting on the tty — the prompt
    # scrolls away under them and the run looks like it printed its whole result
    # and then hung. Held in a file and replayed once age has its passphrase.
    local manifest rc=0
    manifest=$(mktemp)
    ssh -o BatchMode=yes "$target" "bash -s ${STATE_PATHS[*]}" 2>"$manifest" <<'REMOTE' | age -p -o "$out.tmp" || rc=$?
set -eu
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT INT TERM
for p in "$@"; do
    [ -e "$HOME/$p" ] || continue
    mkdir -p "$stage/home/$(dirname "$p")"
    cp -a "$HOME/$p" "$stage/home/$(dirname "$p")/"
done
sudo -n cat /var/lib/tailscale/tailscaled.state > "$stage/tailscaled.state" 2>/dev/null \
    || rm -f "$stage/tailscaled.state"
tar -C "$stage" -czvf - .
REMOTE
    # Held stderr has to be released on the failure path too, or a host that
    # refused says nothing at all and the file is the only place the reason went.
    if [ "$rc" != 0 ]; then
        cat "$manifest" >&2
        rm -f "$manifest" "$out.tmp"
        err "Snapshot failed"
        exit "$rc"
    fi
    mv "$out.tmp" "$out"

    ok "Wrote $out ($(du -h "$out" | cut -f1))"
    info "Captured:"
    # Directories dropped, and the two roots named as what they actually are —
    # the raw list is ./home/... plus a bare ./tailscaled.state, which tells you
    # where they sat in the archive rather than where they came from.
    grep -v '/$' "$manifest" \
        | sed -e 's|^\./home/|  ~/|' -e 's|^\./tailscaled.state$|  the Tailscale node identity|'
    rm -f "$manifest"
    case "$out" in
        "$STATE_REPO/"*)
            info "The next 'dots backup create' pushes it off-site with your"
            info "projects archive. To send it now, on its own:"
            info "  cd $STATE_REPO && git add -A && git commit -m 'droplet state' && git push"
            ;;
    esac
    warn "Re-snapshot after any wizard run: OAuth tokens rotate, and a stale"
    warn "archive restores a dead login."
}

cmd_restore() {
    have age || { err "age is not installed"; exit 1; }
    local target archive
    archive="${1:-$(state_archive)}"
    if [ ! -f "$archive" ]; then
        err "No snapshot at $archive"
        # The archive may well exist and simply not be here yet: on a rebuilt
        # desktop it is still in the backup repo on GitHub, and state_archive
        # falls back to ~/Backups the moment that clone is absent — which reads
        # as "you never took one" when the truth is "you never fetched it".
        [ -d "$STATE_REPO/.git" ] \
            && info "Take one with 'dots droplet snapshot'" \
            || info "On a fresh desktop, clone the backup repo first ('dots backup restore' does it), then retry"
        exit 1
    fi
    target=$(require_target)

    header "Restoring credentials onto $DROPLET_NAME"
    info "From $archive"
    warn "This overwrites the host's keys and logins with the snapshot's — including"
    warn "the keypair 'setup' just generated, which is the point: the snapshot's key"
    warn "is the one already registered on GitHub and Forgejo."
    warn "If the OLD droplet is still online, stop here: restoring its Tailscale"
    warn "identity onto a second live machine puts two nodes on one node key."

    # The script travels as ssh's command argument, not on stdin — stdin is the
    # decrypted tar. Single-quoted here and free of single quotes inside, so the
    # remote shell receives it verbatim. A fixed staging dir rather than a trap,
    # for the same reason: no nested quoting.
    #
    # The Tailscale swap goes last, and detached. Restoring onto a host that is
    # already on the tailnet means this very ssh connection runs THROUGH
    # tailscaled: stopping it inline kills the session mid-script, so the
    # matching `start` never runs and the host is left off the tailnet with its
    # public IP closed — reachable only from the DO web console. A transient
    # systemd unit is owned by systemd, not by this session, so the connection
    # dropping cannot interrupt it. Everything that needs a live connection
    # therefore happens above it.
    #
    # 255 is ssh's "the connection died", and here that is the DOCUMENTED
    # outcome, not a failure: restoring over the tailnet means the swap cuts the
    # very connection carrying it. Named explicitly, because the alternative is
    # to make correctness depend on the unit's `sleep` winning a race against
    # every warn/ok line and every network condition below — an unmeasurable
    # constant. The sleep stays, but as a courtesy that keeps the common case
    # tidy rather than as the thing holding the exit status up.
    local rc=0
    age -d "$archive" | ssh -o BatchMode=yes "$target" '
        set -eu
        stage=$HOME/.cache/droplet-state
        rm -rf "$stage"; mkdir -p "$stage"
        tar -C "$stage" -xzf -
        cp -a "$stage/home/." "$HOME/"
        systemctl --user restart t3code 2>/dev/null || true
        echo "  credentials in place, t3code restarted"
        if [ -s "$stage/tailscaled.state" ]; then
            sudo -n install -m 600 -o root -g root \
                "$stage/tailscaled.state" /var/lib/tailscale/tailscaled.state.new
            sudo -n systemd-run --collect --unit=droplet-ts-restore /bin/sh -c \
                "sleep 5; systemctl stop tailscaled; mv /var/lib/tailscale/tailscaled.state.new /var/lib/tailscale/tailscaled.state; systemctl start tailscaled"
            echo "  tailscale: node identity swap queued in a transient unit"
        fi
        rm -rf "$stage"
    ' || rc=$?
    [ "$rc" = 0 ] || [ "$rc" = 255 ] || exit "$rc"

    ok "Credentials restored"
    info "If the tailnet identity was in the archive, the MagicDNS name — and so"
    info "the URL your devices are paired to — comes back unchanged. A connection"
    info "made over that tailnet drops for a few seconds while it swaps; expected."
    warn "The swap is queued, not done. Wait for the host to answer on the tailnet"
    warn "before running 'firewall' — its check would otherwise pass against the"
    warn "pre-swap daemon and close the public IP on an identity nothing proved."
}

cmd_destroy() {
    require_doctl
    local id fw
    id=$(droplet_id)
    [ -n "$id" ] || { info "No droplet named $DROPLET_NAME"; }

    fw=$(firewall_id)
    [ -n "$fw" ] && doctl compute firewall delete "$fw" --force && ok "Firewall deleted"
    [ -n "$id" ] && doctl compute droplet delete "$id" --force && ok "Droplet deleted"

    # `delete` returns before the droplet leaves the listing, so a destroy
    # immediately followed by a create finds the old one still there and skips
    # the create — reporting success while changing nothing.
    for _ in $(seq 60); do
        [ -z "$(droplet_ip)" ] && { ok "Deletion settled"; return 0; }
        sleep 5
    done
    warn "Droplet still listed after 5 minutes — check the DO console"
    return 0
}

cmd_status() {
    require_doctl
    local ip
    ip=$(droplet_ip)
    if [ -z "$ip" ]; then
        warn "No droplet named $DROPLET_NAME"
        return 0
    fi
    ok "$DROPLET_NAME at $ip"
    [ -n "$(firewall_id)" ] && ok "Firewall present" || warn "No firewall yet"
    # Fed on stdin rather than shipped to /tmp and run: one connection instead of
    # two, and nothing left behind — a reboot clears /tmp, which is what once
    # made a live host report as down.
    local target
    if target=$(host_target); then
        ssh -o BatchMode=yes "$target" 'bash -s report' < "$0"
    else
        warn "No SSH on the public IP — expected once the firewall is on; reach it over the tailnet"
    fi
}

# ── Remote half: runs on the droplet ─────────────────────────────────────────


phase_base() {
    header "Base packages"
    # cloud-init is still running `package_update` when SSH first answers, and it
    # holds the apt lock. Connecting successfully is not the same as the machine
    # being ready — without this wait the very first provisioning run dies on
    # "Could not get lock /var/lib/apt/lists/lock" and looks like a script bug.
    if command -v cloud-init >/dev/null 2>&1; then
        info "Waiting for cloud-init to finish..."
        sudo cloud-init status --wait >/dev/null 2>&1 || true
    fi
    sudo apt-get update -qq
    # `direnv` is socle's entry point; age/sops decrypt its .env.enc; the rest is
    # what every one of these repos assumes exists. `just` is deliberately NOT
    # here — see phase_just.
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        build-essential ca-certificates curl git jq unzip zstd \
        direnv age ripgrep fd-find python3-venv rsync
    ok "Base packages installed"
}

phase_swap() {
    header "Swap"
    if swapon --show 2>/dev/null | grep -q /swapfile; then
        ok "Swap already active"
        return 0
    fi
    # 8 GB is not for running more at once — it is so a spike (a Chromium plus
    # two dev servers) degrades instead of tripping the OOM killer on whichever
    # agent session happened to be largest.
    sudo fallocate -l "${SWAP_GB}G" /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap -q /swapfile
    sudo swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    ok "${SWAP_GB}G swap active"
}

# Ubuntu 24.04 ships just 1.21, and socle's justfiles use the `[group]` and
# `[doc]` attributes that landed in 1.27 — apt's build parses none of them, so
# `just dev` fails on the recipe list before it runs anything. The upstream
# installer is the only version that tracks the desktop's.
phase_just() {
    header "just"
    local want=1.27 have_ver
    if have just; then
        have_ver=$(just --version | awk '{print $2}')
        if [ "$(printf '%s\n%s\n' "$want" "$have_ver" | sort -V | head -1)" = "$want" ]; then
            ok "just $have_ver is recent enough"
            return 0
        fi
        warn "just $have_ver predates the [group] attribute — replacing it"
        sudo apt-get remove -y -qq just >/dev/null 2>&1 || true
    fi
    mkdir -p "$HOME/.local/bin"
    # --force: the installer errors out rather than overwriting, so without it
    # any repair run over an existing binary fails instead of replacing it.
    curl -fsSL https://just.systems/install.sh \
        | bash -s -- --force --to "$HOME/.local/bin" >/dev/null
    ok "just $(just --version | awk '{print $2}') installed"
}

phase_linger() {
    header "systemd linger"
    # Without this the T3 Code user unit stops the moment the SSH session that
    # started it ends — everything works while you are connected and dies when
    # you hang up, which is the exact failure this whole host exists to avoid.
    if loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q 'Linger=yes'; then
        ok "Linger already enabled for $USER"
    else
        sudo loginctl enable-linger "$USER"
        ok "Linger enabled for $USER"
    fi
}

phase_docker() {
    header "Docker"
    if have docker; then
        ok "Docker already installed"
    else
        curl -fsSL https://get.docker.com | sudo sh
        ok "Docker installed"
    fi
    if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
        ok "$USER already in the docker group"
    else
        sudo usermod -aG docker "$USER"
        warn "$USER added to the docker group — takes effect on the next login"
    fi
}

phase_nix() {
    header "Nix"
    if have nix || [ -e /nix/var/nix/profiles/default/bin/nix ]; then
        ok "Nix already installed"
        return 0
    fi
    # socle's .envrc does `has nix && use flake`, so the flake is what gives the
    # host the same toolchain versions as the desktop. Determinate's installer
    # turns flakes on by default, which the upstream one does not.
    curl -fsSL https://install.determinate.systems/nix | \
        sh -s -- install linux --no-confirm --init systemd
    ok "Nix installed"
}

# The installer's profile snippet lives in /etc/profile.d, which only login
# shells read — so `nix` is absent from the shells agents actually get, and
# socle's `has nix && use flake` silently takes the no-Nix branch. One line in
# .bashrc is what makes the flake the toolchain rather than a coin flip.
phase_nix_shell() {
    local snippet='. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
    [ -e "${snippet#. }" ] || return 0
    if grep -qF "$snippet" "$HOME/.bashrc" 2>/dev/null; then
        ok "Nix already on interactive shells' PATH"
        return 0
    fi
    printf '\n# Nix — socle'"'"'s flake toolchain\n%s\n' "$snippet" >> "$HOME/.bashrc"
    ok "Nix added to .bashrc"
}

phase_node() {
    header "Node (fnm)"
    export FNM_DIR="$HOME/.local/share/fnm"
    if [ ! -x "$FNM_DIR/fnm" ]; then
        curl -fsSL https://fnm.vercel.app/install | \
            bash -s -- --install-dir "$FNM_DIR" --skip-shell
    fi
    export PATH="$FNM_DIR:$PATH"
    eval "$("$FNM_DIR/fnm" env --shell bash)"
    # T3 Code needs 22.16+/23.11+/24.10+; the current LTS clears that with room.
    "$FNM_DIR/fnm" install --lts >/dev/null 2>&1 || true
    "$FNM_DIR/fnm" default lts-latest >/dev/null 2>&1 || true

    # Prefer the stable alias path over a per-shell multishell dir, so a unit
    # file or a cron entry keeps working across node upgrades.
    local node_bin="$FNM_DIR/aliases/default/bin"
    if ! grep -q 'fnm env' "$HOME/.bashrc" 2>/dev/null; then
        cat >> "$HOME/.bashrc" <<'EOF'

# fnm — Node for the agent CLIs and T3 Code
export FNM_DIR="$HOME/.local/share/fnm"
export PATH="$FNM_DIR:$FNM_DIR/aliases/default/bin:$PATH"
command -v fnm >/dev/null && eval "$(fnm env --shell bash)"
EOF
    fi
    ok "Node $("$node_bin/node" --version 2>/dev/null || echo '?') installed"
}

phase_tools() {
    header "uv, sops, gh, tea"
    have uv || curl -LsSf https://astral.sh/uv/install.sh | sh
    have uv && ok "uv present"

    # sops is not in Ubuntu's archive; the .deb from the release page is the
    # supported way and keeps apt aware of it.
    #
    # The version is resolved, not pinned, and that is load-bearing: a pinned
    # 3.9.4 could not decrypt socle's .env.enc at all. Its recipients are SSH
    # keys, and reading one as an age identity — what SOPS_AGE_SSH_PRIVATE_KEY_FILE
    # selects — only arrived after 3.9. The failure surfaced as "Failed to get
    # the data key required to decrypt", which names neither ssh nor the version.
    local want ver
    want=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest 2>/dev/null \
           | jq -r '.tag_name // empty' | sed 's/^v//')
    want="${want:-3.13.3}"
    ver=$(sops --version 2>/dev/null | awk '{print $2}')
    if [ "$ver" != "$want" ]; then
        local deb
        deb=$(mktemp --suffix=.deb)
        if curl -fsSL -o "$deb" \
             "https://github.com/getsops/sops/releases/download/v${want}/sops_${want}_amd64.deb"; then
            sudo dpkg -i "$deb" >/dev/null
        else
            warn "Could not fetch sops $want — keeping ${ver:-none}"
        fi
        rm -f "$deb"
    fi
    have sops && ok "sops $(sops --version 2>/dev/null | awk '{print $2}') present"

    if ! have gh; then
        sudo mkdir -p -m 755 /etc/apt/keyrings
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh
    fi
    have gh && ok "gh present"

    # tea is Gitea's CLI and speaks Forgejo — it is how screenshots reach a PR
    # on git.o27.io.
    #
    # Resolved, not pinned, for the same reason as sops above and with the same
    # symptom: a pinned 0.9.2 is a 2022 build (its bundled go-sdk is dated
    # 2022-08) and `tea logins add` against a current Forgejo simply never
    # stored a login — three valid tokens in a row went in and nothing came out.
    # tea colours its own version number (`Version: \033[1m0.15.1\033[0m`), so a
    # pattern anchored on a digit right after the label captures the escape and
    # returns nothing — which made every comparison mismatch and re-downloaded
    # tea on each setup. Take the first version-shaped number instead.
    tea_version() { tea --version 2>/dev/null | tr -d '\033' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }
    local tea_want tea_have
    tea_want=$(curl -fsSL 'https://gitea.com/api/v1/repos/gitea/tea/releases?limit=1' 2>/dev/null \
               | jq -r '.[0].tag_name // empty' | sed 's/^v//')
    tea_want="${tea_want:-0.15.1}"
    tea_have=$(tea_version)
    if [ "$tea_have" != "$tea_want" ]; then
        mkdir -p "$HOME/.local/bin"
        if curl -fsSL -o "$HOME/.local/bin/tea.new" \
             "https://dl.gitea.com/tea/${tea_want}/tea-${tea_want}-linux-amd64"; then
            chmod +x "$HOME/.local/bin/tea.new"
            mv "$HOME/.local/bin/tea.new" "$HOME/.local/bin/tea"
        else
            rm -f "$HOME/.local/bin/tea.new"
            warn "Could not fetch tea $tea_want — keeping ${tea_have:-none}"
        fi
    fi
    have tea && ok "tea $(tea_version) present"
}

phase_agents() {
    header "Agent CLIs and T3 Code"
    have claude || curl -fsSL https://claude.ai/install.sh | bash
    have claude && ok "claude present"

    have codex || npm install -g @openai/codex >/dev/null 2>&1
    have codex && ok "codex present"

    # Upstream, not the fork — see docs/adr/0001. Installed globally so the
    # systemd unit names a stable binary rather than resolving through npx.
    have t3 || npm install -g t3 >/dev/null 2>&1
    have t3 && ok "t3 $(t3 --version 2>/dev/null || echo '') present"
}

# The PATH that matters is the T3 Code unit's, not any shell's.
#
# Agents never run their commands in a login or interactive shell — the service
# spawns them, so they inherit the unit's environment and both /etc/profile and
# .bashrc are skipped. That is why Nix looks fine (Determinate writes
# /etc/environment, which PAM reads) while fnm's node, just, claude and codex do
# not: those live under ~ and nothing exports them to a unit. Left alone, every
# agent-run `npm`, `just` or `claude` is a command not found.
#
# A drop-in rather than environment.d, which the user manager only reads when it
# *starts* — writing it and restarting the service changes nothing, as measured.
# A drop-in also survives `t3 service update` rewriting the unit file.
#
# The paths are the stable ones on purpose: fnm's `aliases/default/bin` outlives
# a node upgrade, a /run/user/*/fnm_multishells/* path does not.
# PATH, plus the one variable socle's tooling cannot work without: its MCP
# servers shell out to `sops -d .env.enc` at startup, and sops finds the SSH key
# behind those recipients only when pointed at it. On the desktop that export
# lives in the shell profile — a systemd unit reads no profile, so it has to be
# stated here or every o27 session starts with a dead MCP server.
phase_env() {
    header "T3 Code unit environment"
    local dir="$HOME/.config/systemd/user/t3code.service.d" file
    file="$dir/10-path.conf"
    local want
    want="[Service]
Environment=SOPS_AGE_SSH_PRIVATE_KEY_FILE=$HOME/.ssh/o27_socle_sops
Environment=PATH=$HOME/.local/bin:$HOME/.local/share/fnm/aliases/default/bin:/nix/var/nix/profiles/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    if [ -f "$file" ] && [ "$(cat "$file")" = "$want" ]; then
        ok "Unit environment already set"
        return 0
    fi
    mkdir -p "$dir"
    printf '%s\n' "$want" > "$file"
    systemctl --user daemon-reload
    if systemctl --user is-active t3code >/dev/null 2>&1; then
        systemctl --user restart t3code
        ok "Unit environment written, T3 Code restarted onto it"
    else
        ok "Unit environment written"
    fi
}

# Needs no human, so it belongs here rather than in the wizard. The server runs
# fine with no provider signed in — it just has nothing to drive yet — and it
# binds to loopback until pairing opens it up, so installing it early exposes
# nothing.
phase_t3_service() {
    header "T3 Code service"
    if systemctl --user is-enabled t3code >/dev/null 2>&1; then
        ok "Service already installed ($(systemctl --user is-active t3code))"
        return 0
    fi
    t3 service install
    systemctl --user is-active t3code >/dev/null 2>&1 \
        && ok "Service active" \
        || warn "Service installed but not active — check ~/.t3/userdata/logs/boot-service.log"
}

phase_playwright() {
    header "Playwright (headless Chromium)"
    # --with-deps is the point: the system libraries Chromium needs are not on a
    # server image, and they are apt packages, so this cannot be done per repo.
    # Chromium only — socle's headless_playwright MCP drives Blink, and the
    # other two engines are 300 MB of nothing.
    if [ -d "$HOME/.cache/ms-playwright" ] && \
       find "$HOME/.cache/ms-playwright" -maxdepth 1 -name 'chromium-*' | grep -q .; then
        ok "Chromium already installed"
        return 0
    fi
    npx --yes playwright@latest install --with-deps chromium
    ok "Chromium installed"
}

phase_tailscale() {
    header "Tailscale"
    if have tailscale; then
        ok "Tailscale already installed"
    else
        curl -fsSL https://tailscale.com/install.sh | sh
        ok "Tailscale installed"
    fi
    if tailscale status >/dev/null 2>&1; then
        ok "Already on the tailnet as $(tailscale ip -4 2>/dev/null)"
        # `tailscale up` runs under sudo, which makes root the daemon's operator
        # — and then an unprivileged `tailscale serve` is refused outright.
        # That is what `t3 pair --tailscale` does, so pairing died on
        # "Access denied: serve config denied" with a stack trace that named
        # neither sudo nor the operator. Reconciled off machine state on every
        # setup rather than only at join time, so a host that joined by any
        # other route is repaired too.
        if [ "$(tailscale debug prefs 2>/dev/null | jq -r '.OperatorUser // empty')" != "$USER" ]; then
            sudo tailscale set --operator="$USER" && ok "Tailscale operator set to $USER"
        else
            ok "Tailscale operator is already $USER"
        fi
    else
        warn "Not on the tailnet yet — the wizard's Tailscale step does that"
    fi
}

phase_sshkey() {
    header "Host git identity"
    local key="$HOME/.ssh/id_ed25519"
    if [ -f "$key" ]; then
        ok "Host key already exists"
    else
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        # Generated here, never copied from the desktop: destroying this host
        # should cost two revocations and touch nothing else.
        ssh-keygen -q -t ed25519 -C "t3code-host" -f "$key" -N ""
        ok "Host key generated"
    fi
    # The backup manifest records each repo's origin URL verbatim, and most of
    # the GitHub ones are https:// — which authenticates by credential helper,
    # not by key. The desktop has a helper; this host deliberately has no
    # keyring at all, so a scoped restore stopped dead on "Username for
    # 'https://github.com'" at its first clone. Rewriting to SSH makes the key
    # we just registered the answer for every GitHub remote, whichever form the
    # manifest happens to carry. The o27 remotes are already ssh://.
    #
    # Rewriting here rather than fixing the URLs is deliberate: the manifest is
    # written by the desktop, so any repair there would have to be redone at
    # every `dots backup create`.
    git config --global url."git@github.com:".insteadOf "https://github.com/"
    ok "GitHub https remotes will authenticate over SSH"

    # sops reads this to find the SSH key behind socle's .env.enc recipients.
    # Set for interactive shells here and for the T3 Code unit in phase_env —
    # the two environments share nothing, and both need it.
    if ! grep -q SOPS_AGE_SSH_PRIVATE_KEY_FILE "$HOME/.bashrc" 2>/dev/null; then
        printf '\n# sops — the SSH key behind o27'"'"'s .env.enc recipients\nexport SOPS_AGE_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/o27_socle_sops"\n' \
            >> "$HOME/.bashrc"
        ok "sops key path exported for interactive shells"
    fi

    # Forgejo's host key has to be known before any clone, or every clone hangs
    # on an interactive prompt nobody is there to answer.
    touch "$HOME/.ssh/known_hosts"
    local h
    # git.o27.io is the forge's current name; the other two are the same host
    # under older ones. All three are scanned because the backup manifest still
    # records origin URLs pointing at the old names — a clone against an
    # unscanned host hangs on a prompt nobody is there to answer.
    for h in github.com git.o27.io git.postula.io git.postulex.be; do
        # `ssh-keygen -F`, not grep: `-H` writes *hashed* hostnames
        # (`|1|base64|base64 …`), so a `^$h ` match can never fire and every run
        # appended the same four keys again — in the one script whose whole
        # contract is that re-running it is the repair.
        ssh-keygen -F "$h" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1 && continue
        ssh-keyscan -H "$h" >> "$HOME/.ssh/known_hosts" 2>/dev/null || warn "Could not scan $h"
    done
    chmod 600 "$HOME/.ssh/known_hosts"
}

# Only this host can answer whether o27's services are IP-filtered — they
# resolve to one public Hetzner address, but an allowlist would be invisible
# from the desktop, which is already on a trusted network.
phase_probe_o27() {
    header "Reachability of o27 services from this IP"
    local host code
    for host in git.o27.io errors.o27.io wiki.o27.io palantir.o27.io; do
        # `|| true`, never `|| echo 000`: curl has *already* written its own
        # "000" (no newline) by the time it exits non-zero, so the fallback
        # concatenated onto it and produced "000000" — which matches no case but
        # `*`, and reported an unreachable host as `ok … answers 000000`. The one
        # answer this phase exists to surface was the one it got wrong.
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$host/" || true)
        case "${code:-000}" in
            000) warn "$host unreachable — allowlist? (curl could not connect)" ;;
            401|403) warn "$host answers $code — reachable, needs auth" ;;
            *) ok "$host answers $code" ;;
        esac
    done
}

cmd_report() {
    export PATH="$HOME/.local/bin:$HOME/.local/share/fnm/aliases/default/bin:$PATH"
    # On the very first run this shell was opened before Nix existed, so its
    # PATH predates /etc/environment being rewritten — without this the report
    # says nix is MISSING on the one run where that is most alarming and least
    # true.
    # shellcheck disable=SC1091
    [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ] && \
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
    local t
    printf 'host      %s\n' "$(hostname)"
    printf 'ram       %s\n' "$(free -h | awk '/^Mem:/ {print $2" total, "$7" available"}')"
    printf 'swap      %s\n' "$(free -h | awk '/^Swap:/ {print $2}')"
    printf 'disk      %s\n' "$(df -h / | awk 'NR==2 {print $4" free of "$2}')"
    for t in node npm t3 claude codex docker nix just direnv uv sops gh tea tailscale; do
        printf '%-9s %s\n' "$t" "$(command -v "$t" >/dev/null && "$t" --version 2>/dev/null | head -1 || echo 'MISSING')"
    done
    printf 'tailnet   %s\n' "$(tailscale ip -4 2>/dev/null || echo 'not joined')"
    printf 'linger    %s\n' "$(loginctl show-user "$USER" --property=Linger 2>/dev/null || echo '?')"
    printf 'chromium  %s\n' "$(find "$HOME/.cache/ms-playwright" -maxdepth 1 -name 'chromium-*' 2>/dev/null | head -1 || echo 'MISSING')"
    printf 't3 unit   %s\n' "$(systemctl --user is-active t3code 2>/dev/null || echo 'not installed')"
}

cmd_remote() {
    # Set once, for every phase. `ssh host 'bash script'` is neither a login nor
    # an interactive shell, so ~/.local/bin is absent from PATH — which made
    # phase_just install a `just` it then could not see on the next run, and try
    # to install it again over the file it had just written.
    export PATH="$HOME/.local/bin:$HOME/.local/share/fnm/aliases/default/bin:$PATH"
    header "Provisioning $(hostname) as $USER"
    phase_base
    phase_just
    phase_swap
    phase_linger
    phase_docker
    phase_nix
    phase_nix_shell
    phase_node
    phase_tools
    phase_agents
    phase_t3_service
    phase_env
    phase_playwright
    phase_tailscale
    phase_sshkey
    phase_probe_o27

    header "Done"
    cmd_report
    echo ""
    ok "Machine-side provisioning complete"
    info "What is left needs you — run tools/droplet-wizard.sh from the desktop:"
    info "  tailscale up · register this key on GitHub + Forgejo · sops key ·"
    info "  claude/codex login · restore secrets · t3 service install · firewall"
    echo ""
    info "This host's public key (register it on both forges):"
    cat "$HOME/.ssh/id_ed25519.pub"
}

case "${1:-}" in
    create)   cmd_create ;;
    setup)    cmd_setup ;;
    firewall) cmd_firewall ;;
    destroy)  cmd_destroy ;;
    status)   cmd_status ;;
    target)   host_target ;;
    pair)     cmd_pair ;;
    snapshot) shift; cmd_snapshot "$@" ;;
    restore)  shift; cmd_restore "$@" ;;
    remote)   cmd_remote ;;
    report)   cmd_report ;;
    help|--help|-h|"") usage ;;
    *) err "Unknown command: $1"; exit 1 ;;
esac
