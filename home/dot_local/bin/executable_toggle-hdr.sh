#!/bin/bash
# Detect, toggle and restore HDR without tying the state to a connector name.
#
# Capability comes from the connected display's EDID (PQ / SMPTE ST 2084),
# while persistence is keyed by its EDID identity. Connector names such as
# DP-3 may change after docking or moving a cable; the EDID does not.
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-${HOME:?HOME not set}/.local/state}/hypr/hdr"
MONITORS_JSON=""

with_lock() {
    local runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
    exec 9>"$runtime_dir/hypr-hdr-$UID.lock" || return 1
    flock -x 9 || return 1
    "$@"
}

refresh_waybar() {
    pkill -RTMIN+9 waybar 2>/dev/null || true
}

notify_error() {
    notify-send -u critical "HDR" "$1" 2>/dev/null || true
}

load_monitors() {
    MONITORS_JSON="$(hyprctl monitors -j 2>/dev/null)" || return 1
    jq -e 'type == "array"' >/dev/null <<<"$MONITORS_JSON"
}

monitor_record() { # $1 = output
    jq -c --arg output "$1" 'first(.[] | select(.name == $output)) // empty' <<<"$MONITORS_JSON"
}

connected_edids() { # $1 = output
    local edid connector_dir
    for edid in /sys/class/drm/card*-"$1"/edid; do
        connector_dir="${edid%/edid}"
        [ -r "$edid" ] || continue
        [ ! -r "$connector_dir/status" ] \
            || [ "$(sed -n '1p' "$connector_dir/status")" = "connected" ] \
            || continue
        printf '%s\n' "$edid"
    done
}

is_hdr_capable() { # $1 = output
    command -v edid-decode >/dev/null || return 1

    # Ten bits or a wide gamut alone do not make a display HDR. Hyprland's HDR
    # preset uses PQ, whose EDID spelling is SMPTE ST 2084 (with optional space).
    # Connector names can exist on several DRM cards; disconnected sysfs EDIDs
    # remain readable but empty, so keep looking until a connected match decodes.
    local edid
    while IFS= read -r edid; do
        if edid-decode "$edid" 2>/dev/null | grep -Eq 'SMPTE ST ?2084'; then
            return 0
        fi
    done < <(connected_edids "$1")
    return 1
}

capable_outputs() {
    local output found=1
    while IFS= read -r output; do
        if is_hdr_capable "$output"; then
            printf '%s\n' "$output"
            found=0
        fi
    done < <(jq -r '.[].name' <<<"$MONITORS_JSON")
    return "$found"
}

monitor_identity() { # $1 = monitor JSON
    local record="$1" output edid fingerprint
    output="$(jq -r '.name' <<<"$record")"
    while IFS= read -r edid; do
        if edid-decode "$edid" >/dev/null 2>&1; then
            fingerprint="$(sha256sum "$edid" | cut -d' ' -f1)"
            printf 'edid\037%s\n' "$fingerprint"
            return 0
        fi
    done < <(connected_edids "$output")

    # Byte-identical EDIDs are inherently indistinguishable; sharing their
    # preference is safer than silently keying it to a port. Non-DRM/virtual
    # outputs fall back to the stable descriptive fields Hyprland exposes.
    jq -r '[
        (.make // ""), (.model // ""), (.serial // ""),
        (.description // ""), (.physicalWidth // 0 | tostring),
        (.physicalHeight // 0 | tostring)
    ] | join("\u001f")' <<<"$record"
}

record_mode() { # $1 = monitor JSON
    jq -r 'if .colorManagementPreset == "hdr" then "hdr" else "sdr" end' <<<"$1"
}

state_file() { # $1 = monitor JSON
    local identity key
    identity="$(monitor_identity "$1")"
    key="$(printf '%s' "$identity" | sha256sum | cut -d' ' -f1)"
    printf '%s/%s.json\n' "$STATE_DIR" "$key"
}

saved_mode() { # $1 = monitor JSON
    local file mode
    file="$(state_file "$1")"
    if [ -r "$file" ]; then
        mode="$(jq -r '.mode // empty' "$file" 2>/dev/null)"
        case "$mode" in hdr|sdr) printf '%s\n' "$mode"; return 0 ;; esac
    fi

    printf 'sdr\n'
}

save_mode() { # $1 = monitor JSON, $2 = hdr|sdr
    local record="$1" mode="$2" file temporary identity description output
    file="$(state_file "$record")"
    temporary="$file.tmp.$$"
    identity="$(monitor_identity "$record")"
    description="$(jq -r '.description // ""' <<<"$record")"
    output="$(jq -r '.name' <<<"$record")"

    mkdir -p -- "$STATE_DIR" || return 1
    if jq -cn \
        --arg mode "$mode" \
        --arg identity "$identity" \
        --arg description "$description" \
        --arg output "$output" \
        '{mode: $mode, identity: $identity, description: $description, last_output: $output}' \
        >"$temporary" && mv -f -- "$temporary" "$file"; then
        return 0
    fi
    unlink "$temporary" 2>/dev/null || true
    return 1
}

current_preset() { # $1 = output
    hyprctl monitors -j 2>/dev/null \
        | jq -r --arg output "$1" 'first(.[] | select(.name == $output) | .colorManagementPreset) // empty'
}

apply_mode() { # $1 = monitor JSON, $2 = hdr|sdr
    local record="$1" target="$2"
    local output mode position scale transform bitdepth cm response actual

    read -r output mode position scale transform < <(jq -r '
        "\(.name) \(.width)x\(.height)@\(.refreshRate) \(.x)x\(.y) \(.scale) \(.transform)"
    ' <<<"$record")
    [[ "$output" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

    if [ "$target" = "hdr" ]; then
        bitdepth=10
        cm=hdr
    else
        bitdepth=8
        cm=srgb
    fi

    response="$(hyprctl -r eval \
        "hl.monitor({ output = '$output', mode = '$mode', position = '$position', scale = $scale, transform = $transform, bitdepth = $bitdepth, cm = '$cm' })" \
        2>/dev/null)" || return 1
    grep -qx ok <<<"$response" || return 1

    # Aquamarine can accept the rule but silently fall back to sRGB when it did
    # not understand the panel's HDR metadata. Persist only observed reality.
    actual="$(current_preset "$output")"
    if [ "$target" = "hdr" ]; then
        [ "$actual" = "hdr" ]
    else
        [ "$actual" = "srgb" ]
    fi
}

select_output() {
    local requested="${HDR_MONITOR:-}" focused output record
    local -a capable=() active_hdr=()

    if [ -n "$requested" ]; then
        monitor_record "$requested" | grep -q . || return 1
        printf '%s\n' "$requested"
        return 0
    fi

    mapfile -t capable < <(capable_outputs)
    case ${#capable[@]} in
        0) return 1 ;;
        1) printf '%s\n' "${capable[0]}"; return 0 ;;
    esac

    focused="$(jq -r 'first(.[] | select(.focused == true) | .name) // empty' <<<"$MONITORS_JSON")"
    for output in "${capable[@]}"; do
        if [ "$output" = "$focused" ]; then
            printf '%s\n' "$output"
            return 0
        fi
        record="$(monitor_record "$output")"
        [ "$(record_mode "$record")" = "hdr" ] && active_hdr+=("$output")
    done

    if [ ${#active_hdr[@]} -eq 1 ]; then
        printf '%s\n' "${active_hdr[0]}"
        return 0
    fi
    return 2
}

toggle() {
    local output record current target result
    load_monitors || { notify_error "Could not query connected monitors"; return 1; }

    output="$(select_output)"
    result=$?
    if [ $result -eq 1 ]; then
        notify_error "No HDR-capable monitor detected"
        return 1
    elif [ $result -eq 2 ]; then
        notify_error "Several HDR monitors are connected; focus the one to toggle"
        return 1
    fi

    record="$(monitor_record "$output")"
    current="$(record_mode "$record")"
    if [ "$current" = "hdr" ]; then target=sdr; else target=hdr; fi

    if ! apply_mode "$record" "$target"; then
        if [ "$target" = "hdr" ]; then
            notify_error "$output advertises HDR, but Hyprland kept it in SDR"
        else
            notify_error "Could not switch $output back to SDR"
        fi
        refresh_waybar
        return 1
    fi

    if ! save_mode "$record" "$target"; then
        notify_error "Switched $output to $target, but could not save the state"
        refresh_waybar
        return 1
    fi

    refresh_waybar
}

restore() {
    local output record desired current
    load_monitors || return 0

    while IFS= read -r output; do
        record="$(monitor_record "$output")"
        desired="$(saved_mode "$record")"
        current="$(record_mode "$record")"
        [ "$desired" = "$current" ] && continue

        if apply_mode "$record" "$desired"; then
            save_mode "$record" "$desired" || true
        elif [ "$desired" = "hdr" ]; then
            notify_error "Could not restore HDR on $output"
        fi
    done < <(capable_outputs)

    refresh_waybar
}

status() {
    local output record mode description text class tooltip="" hdr_count=0
    local -a capable=()
    load_monitors || { printf '{"text":""}\n'; return 0; }
    mapfile -t capable < <(capable_outputs)
    [ ${#capable[@]} -gt 0 ] || { printf '{"text":""}\n'; return 0; }

    for output in "${capable[@]}"; do
        record="$(monitor_record "$output")"
        mode="$(record_mode "$record")"
        description="$(jq -r '.description // .name' <<<"$record")"
        [ "$mode" = "hdr" ] && hdr_count=$((hdr_count + 1))
        tooltip+="${tooltip:+$'\n'}$description ($output): ${mode^^}"
    done

    if [ ${#capable[@]} -eq 1 ]; then
        if [ $hdr_count -eq 1 ]; then text=HDR; class=hdr; else text=SDR; class=sdr; fi
    elif [ $hdr_count -eq 0 ]; then
        text=SDR; class=sdr
    elif [ $hdr_count -eq ${#capable[@]} ]; then
        text="HDR ×${#capable[@]}"; class=hdr
    else
        text="HDR $hdr_count/${#capable[@]}"; class=mixed
    fi

    jq -cn --arg text "$text" --arg class "$class" --arg tooltip "$tooltip" \
        '{text: $text, class: $class, tooltip: $tooltip}'
}

case "${1:-toggle}" in
    toggle)    with_lock toggle ;;
    --restore) with_lock restore ;;
    --status)  status ;;
    --capable)
        load_monitors || exit 1
        capable_outputs
        ;;
    *)
        printf 'Usage: %s [toggle|--restore|--status|--capable]\n' "${0##*/}" >&2
        exit 2
        ;;
esac
