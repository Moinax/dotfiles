#!/bin/bash
# Gaming HDR Launch Helper — generate the Steam launch string that actually
# enables HDR on *this* machine, pre-filled from the connected HDR monitor.
#
# Two routes exist and the right one depends on the GPU:
#   - native  : Proton's own Wayland HDR (PROTON_ENABLE_WAYLAND/_HDR). The
#               reliable path on NVIDIA, whose driver (>=595) carries the HDR
#               WSI natively and whose nested-gamescope support is unreliable.
#   - gamescope: wraps the game in gamescope --hdr-enabled. The reliable path on
#               AMD; on NVIDIA the WSI layer often fails to advertise HDR to the
#               game (in-game toggle greyed out), so it is not the default there.
#
# Steam launch options live inside Steam's own per-game config, not in this
# repo, so this helper only *generates* the string (and copies it to the
# clipboard). You paste it into the game's Properties → Launch Options box.
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared utilities
source "$REPO_DIR/install/lib/common.sh"
source "$REPO_DIR/install/lib/detect.sh"

install_interrupt_trap

# ── Preconditions ──────────────────────────────────────────────────────────────

# --check: report whether an HDR monitor is available (exit 0/1, no output).
# manage.sh gates its "Gaming HDR launch" menu entry on this, so the HDR
# detection lives only in this script.
check_only=false
[ "${1:-}" = "--check" ] && check_only=true

if $check_only; then
    command_exists hyprctl && command_exists jq || exit 1
else
    require_tools hyprctl jq || exit 1
fi

# ── Find HDR monitor(s) ─────────────────────────────────────────────────────────
# A monitor is HDR-capable in the running session when Hyprland reports its
# colorManagementPreset as "hdr" (driven by the `cm,hdr` flag in monitor.conf).

monitors_json=$(hyprctl monitors -j 2>/dev/null) || monitors_json=""

mapfile -t hdr_monitors < <(
    jq -r '.[] | select(.colorManagementPreset == "hdr") | .name' <<< "$monitors_json"
)

if $check_only; then
    [ ${#hdr_monitors[@]} -gt 0 ] && exit 0
    exit 1
fi

if [ ${#hdr_monitors[@]} -eq 0 ]; then
    print_error "No HDR monitor found in the current Hyprland session"
    print_info "Add 'cm,hdr' (and 'bitdepth,10') to the monitor in monitor.conf.tmpl,"
    print_info "then re-apply with chezmoi and reload Hyprland."
    exit 1
fi

# Pick the monitor: auto when there's one, prompt otherwise.
monitor=""
if [ ${#hdr_monitors[@]} -eq 1 ]; then
    monitor="${hdr_monitors[0]}"
else
    if ! command_exists gum; then
        print_error "Multiple HDR monitors found and gum is unavailable to choose"
        exit 1
    fi
    monitor=$(printf '%s\n' "${hdr_monitors[@]}" \
        | gum choose --cursor.foreground="212" --header "Select the HDR monitor to target:") || {
        echo "Cancelled."
        exit 0
    }
fi

# Pull geometry for the chosen monitor (used by the gamescope route). Refresh is
# a float (e.g. 174.96201); gamescope wants an integer, so round to nearest.
read -r width height refresh < <(
    jq -r --arg n "$monitor" \
        '.[] | select(.name == $n) | "\(.width) \(.height) \((.refreshRate + 0.5 | floor))"' \
        <<< "$monitors_json"
)

if [ -z "$width" ] || [ -z "$height" ] || [ -z "$refresh" ]; then
    print_error "Could not read geometry for monitor '$monitor'"
    exit 1
fi

print_info "HDR monitor: $monitor — ${width}x${height} @ ${refresh}Hz"

# ── Detect GPU and choose the recommended route ─────────────────────────────────

is_nvidia=false
nvidia_major=""
if lspci 2>/dev/null | grep -qi 'nvidia'; then
    is_nvidia=true
    if command_exists nvidia-smi; then
        nvidia_major=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
        nvidia_major="${nvidia_major%%.*}"
    fi
fi

# NVIDIA → native; everything else (AMD/Intel) → gamescope.
if $is_nvidia; then
    recommended="native"
    print_info "GPU: NVIDIA${nvidia_major:+ (driver $nvidia_major)} — native Proton Wayland HDR recommended"
else
    recommended="gamescope"
    print_info "GPU: non-NVIDIA — gamescope HDR recommended"
fi

# Let the user override the route; preselect the recommended one.
method="$recommended"
if command_exists gum; then
    opts=()
    if [ "$recommended" = "native" ]; then
        opts=("native — Proton Wayland HDR (recommended)" "gamescope — wrap in gamescope --hdr-enabled")
    else
        opts=("gamescope — wrap in gamescope --hdr-enabled (recommended)" "native — Proton Wayland HDR")
    fi
    choice=$(printf '%s\n' "${opts[@]}" \
        | gum choose --cursor.foreground="212" --header "HDR method:") || {
        echo "Cancelled."
        exit 0
    }
    method="${choice%% *}"   # first word: "native" or "gamescope"
fi

# ── Optional add-ons (shared) ───────────────────────────────────────────────────

want_mango=false want_gamemode=false want_itm=false
if command_exists gum; then
    addon_opts=()
    [ "$method" = "gamescope" ] && addon_opts+=("Inverse tone-mapping (fake HDR for SDR-only games)")
    addon_opts+=("MangoHud FPS overlay")
    addon_opts+=("GameMode performance daemon")
    selected=$(printf '%s\n' "${addon_opts[@]}" | gum choose --no-limit --cursor.foreground="212" \
        --header "Optional add-ons (space to select, enter to confirm):") || selected=""
    grep -q "Inverse tone-mapping" <<< "$selected" && want_itm=true
    grep -q "MangoHud"             <<< "$selected" && want_mango=true
    grep -q "GameMode"             <<< "$selected" && want_gamemode=true
fi

# ── Assemble the launch string ───────────────────────────────────────────────────

if [ "$method" = "native" ]; then
    # Proton's native Wayland HDR. Env vars first, then command wrappers.
    parts=("PROTON_ENABLE_WAYLAND=1" "PROTON_ENABLE_HDR=1")
    $is_nvidia && parts+=("ENABLE_HDR_WSI=1")
    $want_gamemode && parts+=("gamemoderun")
    $want_mango && parts+=("mangohud")
    parts+=("%command%")
    launch="${parts[*]}"
else
    # gamescope route.
    if ! command_exists gamescope; then
        print_warning "gamescope is not installed — the generated string won't run until it is"
        print_info "Install it via the Gaming package group (./manage.sh packages)"
    fi
    gs_args=(-W "$width" -H "$height" -r "$refresh" --hdr-enabled)
    $want_itm && gs_args+=(--hdr-itm-enabled)
    gs_args+=(-f)
    $want_mango && gs_args+=(--mangoapp)
    post=()
    $want_gamemode && post+=(gamemoderun)
    post+=(%command%)
    launch="DXVK_HDR=1 gamescope ${gs_args[*]} -- ${post[*]}"
fi

# ── Output ──────────────────────────────────────────────────────────────────────

echo
print_success "Steam launch options:"
echo
echo "    $launch"
echo

if command_exists wl-copy; then
    printf '%s' "$launch" | wl-copy
    print_info "Copied to clipboard — paste into the game's Properties → Launch Options."
else
    print_info "Paste this into the game's Properties → Launch Options."
fi

# Method-specific guidance.
if [ "$method" = "native" ]; then
    print_info "Launch the game FULLSCREEN on '$monitor' — HDR only engages for fullscreen content."
    print_warning "Requires GE-Proton — native HDR does NOT work on stock Proton 11 / Experimental."
    print_info "Set it per game via Properties → Compatibility → GE-Proton (install with ProtonPlus/ProtonUp-Qt)."
    print_warning "PROTON_ENABLE_WAYLAND breaks the Steam overlay and can affect controllers."
    if $is_nvidia && [ -n "$nvidia_major" ] && [ "$nvidia_major" -lt 595 ] 2>/dev/null; then
        print_warning "NVIDIA driver $nvidia_major < 595: also install vk-hdr-layer for HDR WSI support."
    fi
else
    print_info "Enable HDR inside the game's own video settings too."
    $is_nvidia && print_warning "gamescope HDR on NVIDIA is unreliable (nested WSI); prefer the native method if the toggle stays greyed."
fi
