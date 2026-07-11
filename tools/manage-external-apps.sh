#!/bin/bash
# External Apps Manager
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_DIR/install/lib/common.sh"

install_interrupt_trap

APPIMAGE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/AppImages"
APP_DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
APP_ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/external-apps"
DISTROBOX_STATE_DIR="$STATE_DIR/distrobox"
SOURCES_STATE_DIR="$STATE_DIR/sources"

usage() {
    cat <<'EOF'
Usage: ./manage.sh apps [command] [options]

Commands:
  import-appimage <file> [--name NAME]
      Copy an AppImage to a stable location and create a desktop launcher.

  remove-appimage [--name NAME]
      Remove an installed AppImage, its desktop entry, and icon.

  install-distrobox --container NAME --package FILE [--app DESKTOP_ID] [--name APP_NAME] [--args "FLAGS"]
      Install a local package inside a Distrobox container, export it to the host launcher,
      and save metadata for future updates. --args persists launch flags (e.g. "--disable-gpu")
      that are re-applied to the desktop entry after every export.

  update-distrobox --name APP_NAME --package FILE [--args "FLAGS"]
      Update a previously managed Distrobox app using saved metadata. Saved launch args are
      preserved automatically; pass --args to change them (--args "" clears them).

  install-github <owner/repo | github URL> [--name NAME] [--asset GLOB] [--type appimage|package]
                 [--container NAME] [--app DESKTOP_ID] [--args "FLAGS"] [--non-interactive]
      Download the latest GitHub release asset and install it (AppImage → launcher
      import, deb/rpm/pkg.tar → Distrobox install). The source is remembered so the
      app can be kept current with 'check-updates' / 'update'.

  set-source --name APP --repo <owner/repo | github URL> [--asset GLOB] [--version TAG]
      Attach a GitHub release source to an already-installed app. Without --version
      the app reports as updatable until the first 'update' runs.

  check-updates [--porcelain]
      Compare each app's installed version against its latest GitHub release.
      --porcelain prints outdated apps as "name|installed|latest" lines.

  update [--name APP | --all]
      Re-download the latest release asset and reinstall. AppImages are re-imported
      in place; Distrobox apps are reinstalled in their container with saved launch
      args preserved.

  list
      List all managed apps (AppImages and Distrobox apps).

Run without arguments for an interactive wizard:
  - Install app (local file): fuzzy-find a file (.AppImage, .deb, .rpm) and auto-detect the install method
  - Install from GitHub release: paste a repo/URL, pick the asset, install + track updates
  - Manage installed apps: update (from GitHub or a local file) or uninstall any managed app
  - Check for updates: check all tracked apps and pick which to update
EOF
}

ensure_dirs() {
    mkdir -p "$APPIMAGE_DIR" "$APP_DESKTOP_DIR" "$APP_ICON_DIR" "$DISTROBOX_STATE_DIR" "$SOURCES_STATE_DIR"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

# Turn a raw AppImage filename into a human-readable app name
# e.g. "T3-Code-0.0.13-x86_64_e879597ed9181500dac6cae7f7d710a7" → "T3 Code"
humanize_appimage_name() {
    local name="$1"
    # Strip .AppImage suffix if still present
    name="${name%.AppImage}"
    # Remove hex hashes (8+ hex chars preceded by separator)
    name=$(printf '%s' "$name" | sed 's/[_-][0-9a-f]\{8,\}//g')
    # Remove arch strings
    name=$(printf '%s' "$name" | sed 's/[_-]\(x86_64\|aarch64\|arm64\|i686\|armhf\|amd64\|x64\)//gi')
    # Remove version patterns (e.g. -0.0.13, _2.1, -v1.2.3)
    name=$(printf '%s' "$name" | sed 's/[_-]v\?[0-9]\+\(\.[0-9]\+\)*//g')
    # Replace separators with spaces and trim
    name=$(printf '%s' "$name" | tr '_-' '  ' | sed 's/  */ /g; s/^ *//; s/ *$//')
    printf '%s' "$name"
}

require_file() {
    if [ ! -f "$1" ]; then
        print_error "File not found: $1"
        exit 1
    fi
}

refresh_desktop_db() {
    if command_exists update-desktop-database; then
        update-desktop-database "$APP_DESKTOP_DIR" >/dev/null 2>&1 || true
    fi
}

default_picker_root() {
    if [ -d "$HOME/Downloads" ]; then
        printf '%s\n' "$HOME/Downloads"
    else
        printf '%s\n' "$HOME"
    fi
}

prompt_with_default() {
    local header="$1"
    local default_value="$2"
    local placeholder="${3:-}"
    local required="${4:-true}"

    while true; do
        local value=""

        if command_exists gum; then
            value=$(gum input \
                --header "$header" \
                --value "$default_value" \
                --placeholder "$placeholder") || return 1
        else
            printf '%s' "$header"
            if [ -n "$default_value" ]; then
                printf ' [%s]' "$default_value"
            fi
            printf ': '
            IFS= read -r value || return 1
        fi

        value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if [ -z "$value" ] && [ -n "$default_value" ]; then
            value="$default_value"
        fi

        if [ -n "$value" ] || [ "$required" = "false" ]; then
            printf '%s\n' "$value"
            return 0
        fi

        echo -e "${YELLOW}[WARNING]${NC} A value is required." >&2
    done
}

pick_file_from_downloads() {
    local header="$1"
    local mode="$2"
    local root=""
    root=$(default_picker_root)

    # Build glob pattern based on mode (case-insensitive to match e.g. .AppImage and .appimage)
    local -a patterns=()
    case "$mode" in
        appimage) patterns=(-iname '*.AppImage') ;;
        package)  patterns=( \( -iname '*.deb' -o -iname '*.rpm' -o -iname '*.pkg.tar' -o -iname '*.pkg.tar.*' \) ) ;;
        all)      patterns=( \( -iname '*.AppImage' -o -iname '*.deb' -o -iname '*.rpm' -o -iname '*.pkg.tar' -o -iname '*.pkg.tar.*' \) ) ;;
        *)        patterns=(-type f) ;;
    esac

    while true; do
        local selection=""

        if command_exists gum; then
            local -a candidates=()
            mapfile -t candidates < <(find "$root" -maxdepth 3 -type f "${patterns[@]}" 2>/dev/null | sort)

            if [ ${#candidates[@]} -eq 0 ]; then
                print_warning "No matching files found in $root"
                return 1
            fi

            # Show relative paths for readability, resolve back after selection
            local -a display=()
            local c
            for c in "${candidates[@]}"; do
                display+=("${c#"$root"/}")
            done

            local picked=""
            picked=$(printf '%s\n' "${display[@]}" | gum filter --header "$header" --placeholder "Type to search...") || return 1
            selection="$root/$picked"
        else
            selection=$(prompt_with_default "$header" "$root/" "Enter a file path" true) || return 1
        fi

        selection=$(realpath "$selection" 2>/dev/null || true)
        if [ -z "$selection" ] || [ ! -f "$selection" ]; then
            echo -e "${YELLOW}[WARNING]${NC} Please select an existing file." >&2
            continue
        fi

        local selection_lower="${selection,,}"
        case "$mode" in
            appimage)
                if [[ "$selection_lower" != *.appimage ]]; then
                    echo -e "${YELLOW}[WARNING]${NC} Please select a .AppImage file." >&2
                    continue
                fi
                ;;
            package)
                if ! [[ "$selection_lower" == *.deb || "$selection_lower" == *.rpm || "$selection_lower" == *.pkg.tar || "$selection_lower" == *.pkg.tar.* ]]; then
                    echo -e "${YELLOW}[WARNING]${NC} Please select a .deb, .rpm, or .pkg.tar.* file." >&2
                    continue
                fi
                ;;
        esac

        printf '%s\n' "$selection"
        return 0
    done
}

confirm_summary() {
    local title="$1"
    shift
    local lines=("$@")

    if command_exists gum; then
        gum style \
            --border rounded \
            --border-foreground 212 \
            --padding "1 2" \
            --margin "1" \
            "$(gum style --foreground 212 --bold "$title")" \
            "" \
            "${lines[@]}" >/dev/tty
        gum confirm --affirmative "Proceed" --negative "Cancel" "$title?"
    else
        echo ""
        echo "$title"
        echo "========================="
        printf '%s\n' "${lines[@]}"
        echo ""
        read -r -p "Proceed? [y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]]
    fi
}

extract_appimage_metadata() {
    local appimage_path="$1"
    local extract_dir="$2"
    APPIMAGE_META_NAME=""
    APPIMAGE_META_ICON=""
    APPIMAGE_META_MIMETYPE=""
    APPIMAGE_META_CATEGORIES=""

    local work_dir=""
    work_dir=$(mktemp -d)

    chmod +x "$appimage_path"
    if ! spin_run "Extracting AppImage..." \
        bash -c 'cd "$1" && "$2" --appimage-extract >/dev/null 2>&1' _ "$work_dir" "$appimage_path"; then
        rm -rf "$work_dir"
        return 0
    fi

    local squashfs_dir="$work_dir/squashfs-root"
    if [ ! -d "$squashfs_dir" ]; then
        rm -rf "$work_dir"
        return 0
    fi

    rm -rf "$extract_dir"
    mv "$squashfs_dir" "$extract_dir"
    rm -rf "$work_dir"

    local desktop_file=""
    desktop_file=$(find "$extract_dir" -maxdepth 2 -type f -name '*.desktop' | head -1 || true)
    if [ -n "$desktop_file" ]; then
        APPIMAGE_META_NAME=$(sed -n 's/^Name=//p' "$desktop_file" | head -1)
        # Carry over the upstream MIME associations and menu categories. Without
        # MimeType (and a %U in Exec) KDE/KIO treats the app as unable to open
        # URLs and silently falls back to another handler from mimeinfo.cache —
        # e.g. links opening in Chrome even though helium is the default browser.
        APPIMAGE_META_MIMETYPE=$(sed -n 's/^MimeType=//p' "$desktop_file" | head -1)
        APPIMAGE_META_CATEGORIES=$(sed -n 's/^Categories=//p' "$desktop_file" | head -1)
        local icon_name=""
        icon_name=$(sed -n 's/^Icon=//p' "$desktop_file" | head -1)
        if [ -n "$icon_name" ]; then
            # Only accept real image extensions; a bare "$icon_name" match is NOT
            # trusted — Electron apps ship the app *binary* under the same name
            # (Icon=zulip vs ELF ./zulip), which used to get installed as the icon.
            # -L follows the symlinks AppImages typically use for root icons.
            APPIMAGE_META_ICON=$(find -L "$extract_dir" -type f \( -name "${icon_name}.png" -o -name "${icon_name}.svg" -o -name "${icon_name}.xpm" \) | head -1 || true)
        fi
    fi

    if [ -z "$APPIMAGE_META_ICON" ]; then
        # .DirIcon is the AppImage-spec icon (a PNG, usually a symlink)
        if [ -f "$extract_dir/.DirIcon" ]; then
            APPIMAGE_META_ICON="$extract_dir/.DirIcon"
        else
            APPIMAGE_META_ICON=$(find -L "$extract_dir" -type f \( -name '*.png' -o -name '*.svg' -o -name '*.xpm' \) | head -1 || true)
        fi
    fi
}

execute_import_appimage() {
    local source_path="$1"
    local app_name="$2"
    local extract_dir="${3:-}"

    ensure_dirs
    require_file "$source_path"

    if [ -z "$extract_dir" ]; then
        extract_dir=$(mktemp -d)
        trap 'rm -rf "$extract_dir"' RETURN
        extract_appimage_metadata "$source_path" "$extract_dir"
    fi

    local slug=""
    slug=$(slugify "$app_name")
    local dest_appimage="$APPIMAGE_DIR/${slug}.AppImage"
    install -Dm755 "$source_path" "$dest_appimage"

    local icon_path=""
    if [ -n "$APPIMAGE_META_ICON" ] && [ -f "$APPIMAGE_META_ICON" ]; then
        # Take the extension from the basename only — splitting the full path
        # used to pick up dots from the temp dir (…/tmp.tAz0vegP2S/zulip →
        # "tAz0vegP2S/zulip") and create a junk directory under icons/.
        # Extensionless icons (.DirIcon & friends) are PNG per the AppImage spec.
        local icon_ext=""
        case "${APPIMAGE_META_ICON##*/}" in
            *.png) icon_ext="png" ;;
            *.svg) icon_ext="svg" ;;
            *.xpm) icon_ext="xpm" ;;
            *)     icon_ext="png" ;;
        esac
        icon_path="$APP_ICON_DIR/${slug}.${icon_ext}"
        install -Dm644 "$APPIMAGE_META_ICON" "$icon_path"
    fi

    local desktop_file="$APP_DESKTOP_DIR/${slug}.desktop"
    # %U is load-bearing: without a URL field code, KDE/KIO considers the app
    # unable to open links and falls back to another x-scheme-handler from
    # mimeinfo.cache (e.g. Chrome) even when this app is the mimeapps default.
    cat > "$desktop_file" <<EOF
[Desktop Entry]
Name=$app_name
Exec=$dest_appimage %U
Type=Application
Categories=${APPIMAGE_META_CATEGORIES:-Utility;}
Terminal=false
StartupNotify=true
EOF

    if [ -n "$APPIMAGE_META_MIMETYPE" ]; then
        printf 'MimeType=%s\n' "$APPIMAGE_META_MIMETYPE" >> "$desktop_file"
    fi
    if [ -n "$icon_path" ]; then
        printf 'Icon=%s\n' "$icon_path" >> "$desktop_file"
    fi

    refresh_desktop_db
    print_success "Imported AppImage into the launcher"
    echo "  AppImage: $dest_appimage"
    echo "  Desktop entry: $desktop_file"
    if [ -n "$icon_path" ]; then
        echo "  Icon: $icon_path"
    fi
}

do_import_appimage() {
    local source_path=""
    local app_name=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --name)
                app_name="$2"
                shift 2
                ;;
            --help|-h)
                usage
                return 0
                ;;
            *)
                if [ -z "$source_path" ]; then
                    source_path="$1"
                else
                    print_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [ -z "$source_path" ]; then
        print_error "Missing AppImage file path"
        usage
        exit 1
    fi

    source_path=$(realpath "$source_path")
    require_file "$source_path"

    local extract_dir=""
    if [ -z "$app_name" ]; then
        extract_dir=$(mktemp -d)
        trap 'rm -rf "$extract_dir"' RETURN
        extract_appimage_metadata "$source_path" "$extract_dir"
        if [ -n "$APPIMAGE_META_NAME" ]; then
            app_name="$APPIMAGE_META_NAME"
        else
            app_name="$(humanize_appimage_name "$(basename "$source_path")")"
        fi
    fi

    execute_import_appimage "$source_path" "$app_name" "$extract_dir"
}

interactive_import_appimage_with_file() {
    local source_path="$1"
    local default_name="${2:-}"

    local extract_dir=""
    extract_dir=$(mktemp -d)
    trap 'rm -rf "$extract_dir"' RETURN
    extract_appimage_metadata "$source_path" "$extract_dir"

    local detected_name=""
    if [ -n "$default_name" ]; then
        detected_name="$default_name"
    elif [ -n "$APPIMAGE_META_NAME" ]; then
        detected_name="$APPIMAGE_META_NAME"
    else
        detected_name="$(humanize_appimage_name "$(basename "$source_path")")"
    fi

    local app_name=""
    app_name=$(prompt_with_default "App name" "$detected_name" "Launcher name") || return 0

    local slug=""
    slug=$(slugify "$app_name")
    local dest_appimage="$APPIMAGE_DIR/${slug}.AppImage"
    local desktop_file="$APP_DESKTOP_DIR/${slug}.desktop"
    local icon_status="No icon detected"
    if [ -n "$APPIMAGE_META_ICON" ] && [ -f "$APPIMAGE_META_ICON" ]; then
        icon_status="Icon detected: $(basename "$APPIMAGE_META_ICON")"
    fi

    if ! confirm_summary "Import AppImage" \
        "  Source: $source_path" \
        "  Name: $app_name" \
        "  Destination AppImage: $dest_appimage" \
        "  Desktop entry: $desktop_file" \
        "  $icon_status"; then
        print_info "Cancelled."
        return 0
    fi

    execute_import_appimage "$source_path" "$app_name" "$extract_dir"
}

list_installed_appimages() {
    ensure_dirs
    shopt -s nullglob
    local files=("$APPIMAGE_DIR"/*.AppImage)
    shopt -u nullglob
    if [ ${#files[@]} -gt 0 ]; then
        printf '%s\n' "${files[@]}"
    fi
}

execute_remove_appimage() {
    local appimage_path="$1"
    local slug=""
    slug=$(basename "$appimage_path" .AppImage)

    local desktop_file="$APP_DESKTOP_DIR/${slug}.desktop"
    local removed=()

    rm -f "$appimage_path"
    removed+=("AppImage: $appimage_path")

    if [ -f "$desktop_file" ]; then
        rm -f "$desktop_file"
        removed+=("Desktop entry: $desktop_file")
    fi

    shopt -s nullglob
    local icons=("$APP_ICON_DIR/${slug}".*)
    shopt -u nullglob
    local icon
    for icon in "${icons[@]}"; do
        rm -f "$icon"
        removed+=("Icon: $icon")
    done

    local source_file="$SOURCES_STATE_DIR/${slug}.env"
    if [ -f "$source_file" ]; then
        rm -f "$source_file"
        removed+=("Update source: $source_file")
    fi

    refresh_desktop_db
    print_success "Removed AppImage"
    local line
    for line in "${removed[@]}"; do
        echo "  $line"
    done
}

do_remove_appimage() {
    local app_name=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --name)
                app_name="$2"
                shift 2
                ;;
            --help|-h)
                usage
                return 0
                ;;
            *)
                if [ -z "$app_name" ]; then
                    app_name="$1"
                else
                    print_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [ -z "$app_name" ]; then
        print_error "Missing AppImage name"
        usage
        exit 1
    fi

    local slug=""
    slug=$(slugify "$app_name")
    local appimage_path="$APPIMAGE_DIR/${slug}.AppImage"

    if [ ! -f "$appimage_path" ]; then
        print_error "AppImage not found: $appimage_path"
        exit 1
    fi

    execute_remove_appimage "$appimage_path"
}

require_distrobox() {
    if ! command_exists distrobox-enter; then
        print_error "distrobox-enter not found. Is Distrobox installed?"
        return 1
    fi
}

package_type_for_file() {
    case "$1" in
        *.deb) echo "deb" ;;
        *.rpm) echo "rpm" ;;
        *.pkg.tar|*.pkg.tar.*) echo "arch" ;;
        *)
            print_error "Unsupported package format: $1"
            print_info "Supported: .deb, .rpm, .pkg.tar.*"
            return 1
            ;;
    esac
}

run_in_distrobox() {
    local container="$1"
    shift
    distrobox-enter --name "$container" --no-tty -- "$@"
}

resolve_container_package_path_snippet() {
    cat <<'EOF'
host_pkg="$1"
if [ -f "$host_pkg" ]; then
    pkg_path="$host_pkg"
elif [ -f "/run/host$host_pkg" ]; then
    pkg_path="/run/host$host_pkg"
else
    echo "ERROR: package file not visible inside container: $host_pkg" >&2
    exit 12
fi
EOF
}

list_distrobox_containers() {
    if command_exists distrobox; then
        distrobox list --no-color 2>/dev/null \
            | tail -n +2 \
            | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); if ($1 != "") print $1}' \
            | sort -u
        return 0
    fi

    if command_exists distrobox-list; then
        distrobox-list --no-color 2>/dev/null \
            | tail -n +2 \
            | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); if ($1 != "") print $1}' \
            | sort -u
        return 0
    fi

    return 1
}

pick_existing_distrobox_container() {
    local containers=()
    while IFS= read -r line; do
        [ -n "$line" ] && containers+=("$line")
    done < <(list_distrobox_containers || true)

    if [ ${#containers[@]} -eq 0 ]; then
        prompt_with_default "Distrobox container name" "" "Enter a container name" true
        return $?
    fi

    containers+=("Enter container name manually")
    local choice=""

    if command_exists gum; then
        choice=$(printf '%s\n' "${containers[@]}" | gum choose --header "Select a Distrobox container") || return 1
    else
        printf '%s\n' "${containers[@]}"
        choice=$(prompt_with_default "Distrobox container name" "${containers[0]}" "" true) || return 1
    fi

    if [ "$choice" = "Enter container name manually" ]; then
        prompt_with_default "Distrobox container name" "" "Enter a container name" true
        return $?
    fi

    printf '%s\n' "$choice"
}

list_desktop_ids_in_container() {
    local container="$1"
    run_in_distrobox "$container" sh -lc '
        find /usr/share/applications "$HOME/.local/share/applications" \
            -maxdepth 1 -type f -name "*.desktop" 2>/dev/null \
            | xargs -r -n1 basename | sort -u
    '
}

install_package_in_distrobox() {
    local container="$1"
    local package_path="$2"
    local package_type="$3"
    local script=""

    case "$package_type" in
        deb)
            script="$(resolve_container_package_path_snippet)
if command -v apt >/dev/null 2>&1; then
    sudo apt install -y \"\$pkg_path\"
elif command -v dpkg >/dev/null 2>&1; then
    sudo dpkg -i \"\$pkg_path\" || { sudo apt-get install -f -y && sudo dpkg -i \"\$pkg_path\"; }
else
    echo \"ERROR: no Debian package manager found in container\" >&2
    exit 13
fi"
            ;;
        rpm)
            script="$(resolve_container_package_path_snippet)
if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y \"\$pkg_path\"
elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y \"\$pkg_path\"
elif command -v zypper >/dev/null 2>&1; then
    sudo zypper --non-interactive install \"\$pkg_path\"
else
    echo \"ERROR: no RPM package manager found in container\" >&2
    exit 13
fi"
            ;;
        arch)
            script="$(resolve_container_package_path_snippet)
if command -v pacman >/dev/null 2>&1; then
    sudo pacman -U --noconfirm \"\$pkg_path\"
else
    echo \"ERROR: no pacman found in container\" >&2
    exit 13
fi"
            ;;
    esac

    run_in_distrobox "$container" sh -lc "$script" sh "$package_path"
}

select_exported_app_id() {
    local before_file="$1"
    local after_file="$2"
    local requested="$3"

    if [ -n "$requested" ]; then
        printf '%s\n' "$requested"
        return 0
    fi

    local candidates=""
    candidates=$(comm -13 "$before_file" "$after_file" || true)
    local count=""
    count=$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d ' ')

    if [ "$count" -eq 1 ]; then
        printf '%s\n' "$candidates" | sed '/^$/d'
        return 0
    fi

    if [ "$count" -eq 0 ]; then
        print_error "Could not detect a new desktop entry automatically"
    else
        print_error "Multiple desktop entries were added; please specify one with --app"
        printf '%s\n' "$candidates" | sed '/^$/d' | sed 's/^/  - /'
    fi
    return 1
}

pick_exported_app_id_interactive() {
    local before_file="$1"
    local after_file="$2"
    local candidates=()

    while IFS= read -r line; do
        [ -n "$line" ] && candidates+=("$line")
    done < <(comm -13 "$before_file" "$after_file" 2>/dev/null || true)

    if [ ${#candidates[@]} -eq 1 ]; then
        printf '%s\n' "${candidates[0]}"
        return 0
    fi

    if [ ${#candidates[@]} -gt 1 ]; then
        if command_exists gum; then
            printf '%s\n' "${candidates[@]}" | gum choose --header "Pick the desktop entry to export" || return 1
        else
            prompt_with_default "Desktop entry id" "${candidates[0]}" "example.desktop" true || return 1
        fi
        return 0
    fi

    prompt_with_default "Desktop entry id" "" "example.desktop" true
}

export_distrobox_app() {
    local container="$1"
    local app_id="${2%.desktop}"
    run_in_distrobox "$container" distrobox-export --app "$app_id"
}

# Locate the host-side desktop file that distrobox-export created for an app.
# distrobox names it "<container>-<appid>.desktop", with a couple of fallbacks.
find_exported_desktop_file() {
    local app_id="$1"
    local container="$2"
    local app_basename=""
    app_basename=$(basename "$app_id" .desktop)

    local -a candidates=(
        "$APP_DESKTOP_DIR/${container}-${app_basename}.desktop"
        "$APP_DESKTOP_DIR/${app_basename}.desktop"
    )
    local c
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done

    shopt -s nullglob
    local -a globbed=("$APP_DESKTOP_DIR"/*"-${app_basename}.desktop")
    shopt -u nullglob
    if [ ${#globbed[@]} -gt 0 ]; then
        printf '%s\n' "${globbed[0]}"
        return 0
    fi
    return 1
}

# Re-inject saved launch args into the exported desktop file's Exec line(s).
# distrobox-export regenerates the desktop file on every install/update, dropping
# any custom flags (e.g. --disable-gpu), so this must run after each export.
apply_distrobox_app_args() {
    local app_id="$1"
    local container="$2"
    local app_args="$3"

    [ -z "$app_args" ] && return 0

    local desktop_file=""
    if ! desktop_file=$(find_exported_desktop_file "$app_id" "$container"); then
        print_warning "Could not find the exported desktop file; launch args not applied."
        return 0
    fi

    local tmp=""
    tmp=$(mktemp)
    # Insert args before the first field code (%U/%F/...) on each distrobox Exec
    # line, or append them if no field code is present. Skip if already injected.
    DBX_APP_ARGS="$app_args" awk '
        BEGIN { args = ENVIRON["DBX_APP_ARGS"] }
        /^Exec=/ && /distrobox-enter/ && index($0, args) == 0 {
            if (match($0, /[[:space:]]*%[a-zA-Z]/)) {
                pre = substr($0, 1, RSTART - 1)
                field = substr($0, RSTART)
                $0 = pre " " args field
            } else {
                sub(/[[:space:]]+$/, "")
                $0 = $0 " " args
            }
        }
        { print }
    ' "$desktop_file" > "$tmp" && mv "$tmp" "$desktop_file" || { rm -f "$tmp"; return 1; }

    print_info "Applied launch args to '$(basename "$desktop_file")': $app_args"
    refresh_desktop_db
}

metadata_file_for_name() {
    printf '%s/%s.env\n' "$DISTROBOX_STATE_DIR" "$(slugify "$1")"
}

save_distrobox_metadata() {
    local app_name="$1"
    local container="$2"
    local package_type="$3"
    local app_id="$4"
    local app_args="${5:-}"
    local metadata_file=""
    metadata_file=$(metadata_file_for_name "$app_name")

    {
        printf 'APP_NAME=%q\n' "$app_name"
        printf 'CONTAINER=%q\n' "$container"
        printf 'PACKAGE_TYPE=%q\n' "$package_type"
        printf 'APP_ID=%q\n' "$app_id"
        printf 'APP_ARGS=%q\n' "$app_args"
    } > "$metadata_file"
}

load_distrobox_metadata() {
    local app_name="$1"
    local metadata_file=""
    metadata_file=$(metadata_file_for_name "$app_name")
    if [ ! -f "$metadata_file" ]; then
        print_error "No saved metadata for app: $app_name"
        return 1
    fi
    # Reset optional fields so values don't leak from a previously sourced file.
    APP_ARGS=""
    # shellcheck disable=SC1090
    source "$metadata_file"
    APP_ARGS="${APP_ARGS:-}"
}

execute_install_distrobox() {
    local container="$1"
    local package_path="$2"
    local app_name="$3"
    local requested_app_id="$4"
    local app_args="${5:-}"

    ensure_dirs
    require_distrobox || return 1
    require_file "$package_path"

    local package_type=""
    package_type=$(package_type_for_file "$package_path") || return 1

    local before_file=""
    local after_file=""
    before_file=$(mktemp)
    after_file=$(mktemp)
    trap 'rm -f "$before_file" "$after_file"' RETURN

    print_info "Collecting desktop entries from container '$container'..."
    list_desktop_ids_in_container "$container" > "$before_file"

    print_info "Installing package in container '$container'..."
    install_package_in_distrobox "$container" "$package_path" "$package_type"

    print_info "Collecting updated desktop entries..."
    list_desktop_ids_in_container "$container" > "$after_file"

    local app_id=""
    app_id=$(select_exported_app_id "$before_file" "$after_file" "$requested_app_id") || return 1

    if [ -z "$app_name" ]; then
        app_name="${app_id%.desktop}"
    fi

    print_info "Exporting '$app_id' to the host launcher..."
    export_distrobox_app "$container" "$app_id"
    apply_distrobox_app_args "$app_id" "$container" "$app_args"
    save_distrobox_metadata "$app_name" "$container" "$package_type" "$app_id" "$app_args"

    print_success "Installed and exported Distrobox app"
    echo "  App: $app_name"
    echo "  Container: $container"
    echo "  Desktop entry: $app_id"
    [ -n "$app_args" ] && echo "  Launch args: $app_args"
}

do_install_distrobox() {
    local container=""
    local package_path=""
    local app_id=""
    local app_name=""
    local app_args=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --container)
                container="$2"
                shift 2
                ;;
            --package)
                package_path="$2"
                shift 2
                ;;
            --app)
                app_id="$2"
                shift 2
                ;;
            --name)
                app_name="$2"
                shift 2
                ;;
            --args)
                app_args="$2"
                shift 2
                ;;
            --help|-h)
                usage
                return 0
                ;;
            *)
                print_error "Unexpected argument: $1"
                exit 1
                ;;
        esac
    done

    if [ -z "$container" ] || [ -z "$package_path" ]; then
        print_error "install-distrobox requires --container and --package"
        usage
        exit 1
    fi

    package_path=$(realpath "$package_path")
    execute_install_distrobox "$container" "$package_path" "$app_name" "$app_id" "$app_args"
}

interactive_install_distrobox_with_file() {
    local package_path="$1"
    require_distrobox || return 0

    local container=""
    container=$(pick_existing_distrobox_container) || return 0

    local package_type=""
    package_type=$(package_type_for_file "$package_path") || return 0

    local suggested_name=""
    suggested_name="$(basename "$package_path")"
    suggested_name="${suggested_name%.deb}"
    suggested_name="${suggested_name%.rpm}"
    suggested_name="${suggested_name%.pkg.tar}"
    suggested_name="${suggested_name%.pkg.tar.zst}"
    suggested_name="${suggested_name%.pkg.tar.xz}"
    suggested_name="${suggested_name%.pkg.tar.gz}"

    local app_name=""
    app_name=$(prompt_with_default "App name" "$suggested_name" "Saved app name" true) || return 0

    local app_args=""
    app_args=$(prompt_with_default "Launch args (optional, e.g. --disable-gpu)" "" "Leave empty for none" false) || return 0

    if ! confirm_summary "Install package in Distrobox" \
        "  Container: $container" \
        "  Package: $package_path" \
        "  Type: $package_type" \
        "  App name: $app_name" \
        "  Launch args: ${app_args:-none}" \
        "  Desktop entry: auto-detect after install"; then
        print_info "Cancelled."
        return 0
    fi

    ensure_dirs
    local before_file=""
    local after_file=""
    before_file=$(mktemp)
    after_file=$(mktemp)
    trap 'rm -f "$before_file" "$after_file"' RETURN

    print_info "Collecting desktop entries from container '$container'..."
    list_desktop_ids_in_container "$container" > "$before_file"

    print_info "Installing package in container '$container'..."
    install_package_in_distrobox "$container" "$package_path" "$package_type" || {
        print_error "Package installation failed."
        return 1
    }

    print_info "Collecting updated desktop entries..."
    list_desktop_ids_in_container "$container" > "$after_file"

    local app_id=""
    app_id=$(pick_exported_app_id_interactive "$before_file" "$after_file") || {
        print_info "Cancelled."
        return 0
    }

    print_info "Exporting '$app_id' to the host launcher..."
    export_distrobox_app "$container" "$app_id" || {
        print_error "Export failed."
        return 1
    }

    apply_distrobox_app_args "$app_id" "$container" "$app_args"
    save_distrobox_metadata "$app_name" "$container" "$package_type" "$app_id" "$app_args"
    print_success "Installed and exported Distrobox app"
    echo "  App: $app_name"
    echo "  Container: $container"
    echo "  Desktop entry: $app_id"
    [ -n "$app_args" ] && echo "  Launch args: $app_args"
}

execute_update_distrobox() {
    local app_name="$1"
    local package_path="$2"
    local app_args_override="${3:-}"
    local app_args_override_set="${4:-0}"

    ensure_dirs
    require_distrobox || return 1
    require_file "$package_path"
    load_distrobox_metadata "$app_name" || return 1

    # Preserve the saved launch args across the update unless explicitly overridden.
    local app_args="$APP_ARGS"
    if [ "$app_args_override_set" = "1" ]; then
        app_args="$app_args_override"
    fi

    local new_package_type=""
    new_package_type=$(package_type_for_file "$package_path") || return 1
    if [ "$new_package_type" != "$PACKAGE_TYPE" ]; then
        print_warning "Saved package type is '$PACKAGE_TYPE' but new file looks like '$new_package_type'"
    fi

    print_info "Updating '$APP_NAME' in container '$CONTAINER'..."
    install_package_in_distrobox "$CONTAINER" "$package_path" "$new_package_type"

    print_info "Refreshing exported desktop entry '$APP_ID'..."
    export_distrobox_app "$CONTAINER" "$APP_ID"
    apply_distrobox_app_args "$APP_ID" "$CONTAINER" "$app_args"
    save_distrobox_metadata "$APP_NAME" "$CONTAINER" "$new_package_type" "$APP_ID" "$app_args"

    print_success "Updated Distrobox app"
    echo "  App: $APP_NAME"
    echo "  Container: $CONTAINER"
    echo "  Desktop entry: $APP_ID"
    [ -n "$app_args" ] && echo "  Launch args: $app_args"
}

execute_remove_distrobox() {
    local metadata_file="$1"

    # shellcheck disable=SC1090
    source "$metadata_file"

    print_info "Removing exported app '$APP_ID' from container '$CONTAINER'..."
    run_in_distrobox "$CONTAINER" distrobox-export --delete --app "$APP_ID" 2>/dev/null || true

    # Clean up lingering host desktop files (distrobox names them as container-appid)
    local app_basename
    app_basename=$(basename "$APP_ID" .desktop)
    shopt -s nullglob
    local -a lingering=(
        "$APP_DESKTOP_DIR/${app_basename}.desktop"
        "$APP_DESKTOP_DIR"/*"-${app_basename}.desktop"
    )
    shopt -u nullglob
    local f
    for f in "${lingering[@]}"; do
        rm -f "$f"
    done

    rm -f "$metadata_file"
    rm -f "$(source_file_for_name "$APP_NAME")"
    refresh_desktop_db

    print_success "Removed Distrobox app"
    echo "  App: $APP_NAME"
    echo "  Container: $CONTAINER"
    echo "  Desktop entry: $APP_ID"
}

do_update_distrobox() {
    local app_name=""
    local package_path=""
    local app_args=""
    local app_args_set=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --name)
                app_name="$2"
                shift 2
                ;;
            --package)
                package_path="$2"
                shift 2
                ;;
            --args)
                app_args="$2"
                app_args_set=1
                shift 2
                ;;
            --help|-h)
                usage
                return 0
                ;;
            *)
                print_error "Unexpected argument: $1"
                exit 1
                ;;
        esac
    done

    if [ -z "$app_name" ] || [ -z "$package_path" ]; then
        print_error "update-distrobox requires --name and --package"
        usage
        exit 1
    fi

    package_path=$(realpath "$package_path")
    execute_update_distrobox "$app_name" "$package_path" "$app_args" "$app_args_set"
}

# ── GitHub release sources ──────────────────────────────────────────────────
# Per-app source metadata lives in $SOURCES_STATE_DIR/<slug>.env and records
# where an app can be re-downloaded from for updates:
#   APP_NAME       display name (its slug ties it to the AppImage / Distrobox app)
#   APP_TYPE       appimage | distrobox
#   SOURCE_REPO    GitHub owner/repo
#   ASSET_PATTERN  glob matched against release asset filenames
#   VERSION        installed release tag ('' = unknown → reported as updatable)

source_file_for_name() {
    printf '%s/%s.env\n' "$SOURCES_STATE_DIR" "$(slugify "$1")"
}

save_source_metadata() {
    local app_name="$1" app_type="$2" repo="$3" pattern="$4" version="$5"
    ensure_dirs
    {
        printf 'APP_NAME=%q\n' "$app_name"
        printf 'APP_TYPE=%q\n' "$app_type"
        printf 'SOURCE_REPO=%q\n' "$repo"
        printf 'ASSET_PATTERN=%q\n' "$pattern"
        printf 'VERSION=%q\n' "$version"
    } > "$(source_file_for_name "$app_name")"
}

load_source_metadata() {
    local app_name="$1"
    local f=""
    f=$(source_file_for_name "$app_name")
    if [ ! -f "$f" ]; then
        print_error "No update source saved for app: $app_name"
        print_info "Attach one with: ./manage.sh apps set-source --name \"$app_name\" --repo owner/repo"
        return 1
    fi
    APP_TYPE="" SOURCE_REPO="" ASSET_PATTERN="" VERSION=""
    # shellcheck disable=SC1090
    source "$f"
}

# Accept "owner/repo" or any github.com URL form (releases page, .git, …) and
# normalize to "owner/repo".
github_normalize_repo() {
    local input="$1"
    local repo="$input"
    repo="${repo#https://}"
    repo="${repo#http://}"
    repo="${repo#www.}"
    repo="${repo#github.com/}"
    repo=$(printf '%s' "$repo" | cut -d'/' -f1-2)
    repo="${repo%.git}"
    if ! printf '%s' "$repo" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
        print_error "Not a GitHub repo: $input (expected owner/repo or a github.com URL)"
        return 1
    fi
    printf '%s\n' "$repo"
}

# Latest release tag only (cheap call for update checks)
github_latest_tag() {
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d'"' -f4
}

# Fetch the latest release of a repo; sets GH_RELEASE_TAG + GH_RELEASE_ASSET_URLS[].
github_fetch_latest_release() {
    local repo="$1"
    GH_RELEASE_TAG=""
    GH_RELEASE_ASSET_URLS=()

    local json=""
    spin_capture json "Fetching latest release of $repo..." \
        curl -fsSL "https://api.github.com/repos/$repo/releases/latest" || true
    GH_RELEASE_TAG=$(printf '%s' "$json" | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)
    mapfile -t GH_RELEASE_ASSET_URLS < <(printf '%s' "$json" \
        | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4)

    if [ -z "$GH_RELEASE_TAG" ]; then
        print_error "Could not fetch the latest release of $repo"
        return 1
    fi
    if [ ${#GH_RELEASE_ASSET_URLS[@]} -eq 0 ]; then
        print_error "The latest release of $repo ($GH_RELEASE_TAG) has no downloadable assets"
        return 1
    fi
}

# Keywords identifying the current CPU arch in asset filenames, and those of
# other arches (used to drop e.g. arm64 assets on an x86_64 host).
current_arch_keywords() {
    case "$(uname -m)" in
        x86_64)        echo "x86_64 x86-64 amd64 x64" ;;
        aarch64|arm64) echo "aarch64 arm64" ;;
        *)             echo "" ;;
    esac
}

other_arch_keywords() {
    case "$(uname -m)" in
        x86_64)        echo "aarch64 arm64 armhf armv7 i686 i386" ;;
        aarch64|arm64) echo "x86_64 x86-64 amd64 x64 armhf armv7 i686 i386" ;;
        *)             echo "" ;;
    esac
}

# Filter the fetched release assets down to installable candidates.
# $1 = glob pattern ('' = any), $2 = type filter (appimage | package | '')
# Sidecar files (.zsync, checksums, …) and other-arch assets are dropped;
# assets naming the current arch are preferred over arch-less ones.
filter_release_assets() {
    local pattern="$1" type_filter="$2"
    local pattern_lower="${pattern,,}"
    local arch_kw other_kw
    arch_kw=$(current_arch_keywords)
    other_kw=$(other_arch_keywords)

    local -a primary=() fallback=()
    local url name_lower kw
    for url in "${GH_RELEASE_ASSET_URLS[@]}"; do
        name_lower="${url##*/}"
        name_lower="${name_lower,,}"

        # Skip sidecar/metadata assets
        case "$name_lower" in
            *.zsync|*.blockmap|*.sha256|*.sha256sum|*.sha512|*.sig|*.asc|*.txt|*.yml|*.yaml|*.json) continue ;;
        esac

        case "$type_filter" in
            appimage) [[ "$name_lower" == *.appimage ]] || continue ;;
            package)  [[ "$name_lower" == *.deb || "$name_lower" == *.rpm || "$name_lower" == *.pkg.tar || "$name_lower" == *.pkg.tar.* ]] || continue ;;
            *)        [[ "$name_lower" == *.appimage || "$name_lower" == *.deb || "$name_lower" == *.rpm || "$name_lower" == *.pkg.tar || "$name_lower" == *.pkg.tar.* ]] || continue ;;
        esac

        if [ -n "$pattern_lower" ]; then
            # shellcheck disable=SC2254
            case "$name_lower" in
                $pattern_lower) ;;
                *) continue ;;
            esac
        fi

        # Drop assets that name another arch (unless they also name ours,
        # e.g. "x64" inside "linux-x64")
        local skip=false has_arch=false
        for kw in $arch_kw; do
            [[ "$name_lower" == *"$kw"* ]] && has_arch=true && break
        done
        if [ "$has_arch" = false ]; then
            for kw in $other_kw; do
                [[ "$name_lower" == *"$kw"* ]] && skip=true && break
            done
        fi
        [ "$skip" = true ] && continue

        if [ "$has_arch" = true ]; then
            primary+=("$url")
        else
            fallback+=("$url")
        fi
    done

    if [ ${#primary[@]} -gt 0 ]; then
        printf '%s\n' "${primary[@]}"
    elif [ ${#fallback[@]} -gt 0 ]; then
        printf '%s\n' "${fallback[@]}"
    fi
}

# Turn a concrete asset filename into a reusable glob by replacing the release
# tag/version with '*' (helium-0.13.3.1-x86_64.AppImage → helium-*-x86_64.AppImage),
# so the saved pattern keeps matching future releases.
derive_asset_pattern() {
    local name="$1" tag="$2"
    local bare="${tag#v}"
    local pattern="$name"
    if [ -n "$bare" ] && [[ "$pattern" == *"$bare"* ]]; then
        pattern="${pattern//"$bare"/*}"
    elif [ -n "$tag" ] && [[ "$pattern" == *"$tag"* ]]; then
        pattern="${pattern//"$tag"/*}"
    fi
    printf '%s\n' "$pattern"
}

# Resolve exactly one asset URL from the fetched release using the saved/given
# pattern + type filter. With several matches: ask (interactive) or take the
# first (non-interactive, e.g. update --all). Runs inside $(...) — messages
# must go to stderr or they'd corrupt the captured URL.
pick_release_asset() {
    local pattern="$1" type_filter="$2" interactive="$3"
    local -a candidates=()
    mapfile -t candidates < <(filter_release_assets "$pattern" "$type_filter")

    if [ ${#candidates[@]} -eq 0 ]; then
        print_error "No release asset matches${pattern:+ pattern '$pattern'} (type: ${type_filter:-any})" >&2
        print_info "Assets in this release:" >&2
        local u
        for u in "${GH_RELEASE_ASSET_URLS[@]}"; do
            echo "  - $(basename "$u")" >&2
        done
        return 1
    fi

    if [ ${#candidates[@]} -eq 1 ]; then
        printf '%s\n' "${candidates[0]}"
        return 0
    fi

    if [ "$interactive" = true ] && command_exists gum; then
        local -a names=()
        local c
        for c in "${candidates[@]}"; do
            names+=("$(basename "$c")")
        done
        local picked=""
        picked=$(printf '%s\n' "${names[@]}" | gum choose --header "Pick the release asset to install") || return 1
        for c in "${candidates[@]}"; do
            if [ "$(basename "$c")" = "$picked" ]; then
                printf '%s\n' "$c"
                return 0
            fi
        done
        return 1
    fi

    print_warning "Multiple assets match; using $(basename "${candidates[0]}") (pass --asset to pin one)" >&2
    printf '%s\n' "${candidates[0]}"
}

# Download a release asset into a fresh temp dir, keeping its real filename
# (package type detection relies on the extension). Sets DOWNLOADED_ASSET_PATH;
# the caller removes its parent dir when done.
download_release_asset() {
    local url="$1"
    local name=""
    name=$(basename "$url")
    local dir=""
    dir=$(mktemp -d)
    DOWNLOADED_ASSET_PATH="$dir/$name"
    if ! spin_run "Downloading $name..." curl -fsSL "$url" -o "$DOWNLOADED_ASSET_PATH"; then
        print_error "Download failed: $url"
        rm -rf "$dir"
        DOWNLOADED_ASSET_PATH=""
        return 1
    fi
}

do_install_github() {
    local repo_input="" app_name="" asset_pattern="" type_filter="" container="" app_id="" app_args="" interactive=true

    while [ $# -gt 0 ]; do
        case "$1" in
            --name) app_name="$2"; shift 2 ;;
            --asset) asset_pattern="$2"; shift 2 ;;
            --type)
                case "$2" in
                    appimage|package) type_filter="$2" ;;
                    *) print_error "Invalid --type: $2 (expected appimage or package)"; return 1 ;;
                esac
                shift 2 ;;
            --container) container="$2"; shift 2 ;;
            --app) app_id="$2"; shift 2 ;;
            --args) app_args="$2"; shift 2 ;;
            --non-interactive) interactive=false; shift ;;
            --help|-h) usage; return 0 ;;
            *)
                if [ -z "$repo_input" ]; then
                    repo_input="$1"
                else
                    print_error "Unexpected argument: $1"
                    return 1
                fi
                shift ;;
        esac
    done

    if [ -z "$repo_input" ]; then
        print_error "install-github requires a GitHub repo (owner/repo or URL)"
        usage
        return 1
    fi

    local repo=""
    repo=$(github_normalize_repo "$repo_input") || return 1
    github_fetch_latest_release "$repo" || return 1
    print_info "Latest release of $repo: $GH_RELEASE_TAG"

    # --container implies a distro package install
    [ -z "$type_filter" ] && [ -n "$container" ] && type_filter="package"

    local asset_url=""
    asset_url=$(pick_release_asset "$asset_pattern" "$type_filter" "$interactive") || return 1
    local asset_name=""
    asset_name=$(basename "$asset_url")

    # Remember a version-agnostic pattern so updates match future releases
    if [ -z "$asset_pattern" ]; then
        asset_pattern=$(derive_asset_pattern "$asset_name" "$GH_RELEASE_TAG")
    fi

    download_release_asset "$asset_url" || return 1
    local download_dir=""
    download_dir=$(dirname "$DOWNLOADED_ASSET_PATH")

    local rc=0
    local app_type=""
    case "${asset_name,,}" in
        *.appimage)
            app_type="appimage"
            if [ -z "$app_name" ]; then
                local extract_dir=""
                extract_dir=$(mktemp -d)
                extract_appimage_metadata "$DOWNLOADED_ASSET_PATH" "$extract_dir"
                if [ -n "$APPIMAGE_META_NAME" ]; then
                    app_name="$APPIMAGE_META_NAME"
                else
                    app_name="$(humanize_appimage_name "$asset_name")"
                fi
                execute_import_appimage "$DOWNLOADED_ASSET_PATH" "$app_name" "$extract_dir" || rc=1
                rm -rf "$extract_dir"
            else
                execute_import_appimage "$DOWNLOADED_ASSET_PATH" "$app_name" || rc=1
            fi
            ;;
        *.deb|*.rpm|*.pkg.tar|*.pkg.tar.*)
            app_type="distrobox"
            if [ -z "$container" ]; then
                if [ "$interactive" = true ]; then
                    container=$(pick_existing_distrobox_container) || rc=1
                else
                    print_error "Package assets need --container NAME"
                    rc=1
                fi
            fi
            if [ "$rc" -eq 0 ]; then
                if [ -z "$app_name" ]; then
                    app_name=$(humanize_appimage_name "$asset_name")
                fi
                execute_install_distrobox "$container" "$DOWNLOADED_ASSET_PATH" "$app_name" "$app_id" "$app_args" || rc=1
            fi
            ;;
        *)
            print_error "Unsupported asset type: $asset_name"
            rc=1
            ;;
    esac

    rm -rf "$download_dir"
    [ "$rc" -eq 0 ] || return 1

    save_source_metadata "$app_name" "$app_type" "$repo" "$asset_pattern" "$GH_RELEASE_TAG"
    print_success "Pinned update source for $app_name"
    echo "  Repo: $repo"
    echo "  Version: $GH_RELEASE_TAG"
    echo "  Asset pattern: $asset_pattern"
}

execute_set_source() {
    local app_name="$1" repo_input="$2" asset_pattern="$3" version="$4"
    ensure_dirs

    local slug=""
    slug=$(slugify "$app_name")

    # Figure out which kind of installed app this is
    local app_type=""
    if [ -f "$APPIMAGE_DIR/${slug}.AppImage" ]; then
        app_type="appimage"
    elif [ -f "$DISTROBOX_STATE_DIR/${slug}.env" ]; then
        app_type="distrobox"
    else
        print_error "No installed app named '$app_name' (no AppImage or managed Distrobox app)"
        print_info "Install it first, or check './manage.sh apps list'"
        return 1
    fi

    local repo=""
    repo=$(github_normalize_repo "$repo_input") || return 1
    github_fetch_latest_release "$repo" || return 1

    # Make sure the pattern (or the type default) matches something downloadable
    local type_filter="package"
    [ "$app_type" = "appimage" ] && type_filter="appimage"
    local asset_url=""
    asset_url=$(pick_release_asset "$asset_pattern" "$type_filter" false) || return 1
    if [ -z "$asset_pattern" ]; then
        asset_pattern=$(derive_asset_pattern "$(basename "$asset_url")" "$GH_RELEASE_TAG")
    fi

    save_source_metadata "$app_name" "$app_type" "$repo" "$asset_pattern" "$version"
    print_success "Saved update source for $app_name"
    echo "  Repo: $repo"
    echo "  Asset pattern: $asset_pattern"
    if [ -n "$version" ]; then
        echo "  Installed version: $version"
    else
        echo "  Installed version: unknown — it will show as updatable until the first 'update' runs"
    fi
}

do_set_source() {
    local app_name="" repo_input="" asset_pattern="" version=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --name) app_name="$2"; shift 2 ;;
            --repo) repo_input="$2"; shift 2 ;;
            --asset) asset_pattern="$2"; shift 2 ;;
            --version) version="$2"; shift 2 ;;
            --help|-h) usage; return 0 ;;
            *) print_error "Unexpected argument: $1"; return 1 ;;
        esac
    done

    if [ -z "$app_name" ] || [ -z "$repo_input" ]; then
        print_error "set-source requires --name and --repo"
        usage
        return 1
    fi

    execute_set_source "$app_name" "$repo_input" "$asset_pattern" "$version"
}

# Compare every app's installed tag against the latest GitHub release.
# --porcelain prints only outdated apps as "name|installed|latest" lines.
do_check_updates() {
    local porcelain=false
    [ "${1:-}" = "--porcelain" ] && porcelain=true
    ensure_dirs

    shopt -s nullglob
    local files=("$SOURCES_STATE_DIR"/*.env)
    shopt -u nullglob

    if [ ${#files[@]} -eq 0 ]; then
        [ "$porcelain" = false ] && print_info "No apps have an update source. Use 'install-github' or 'set-source' first."
        return 0
    fi

    local outdated=0 failed=0
    local file
    for file in "${files[@]}"; do
        APP_NAME="" APP_TYPE="" SOURCE_REPO="" ASSET_PATTERN="" VERSION=""
        # shellcheck disable=SC1090
        source "$file"

        local latest=""
        if [ "$porcelain" = true ]; then
            latest=$(github_latest_tag "$SOURCE_REPO" || true)
        else
            spin_capture latest "Checking $APP_NAME ($SOURCE_REPO)..." github_latest_tag "$SOURCE_REPO" || true
        fi
        if [ -z "$latest" ]; then
            failed=$((failed + 1))
            [ "$porcelain" = false ] && print_warning "$APP_NAME: could not fetch the latest release of $SOURCE_REPO"
            continue
        fi

        if [ "$VERSION" = "$latest" ]; then
            [ "$porcelain" = false ] && print_success "$APP_NAME is up to date ($VERSION)"
        else
            outdated=$((outdated + 1))
            if [ "$porcelain" = true ]; then
                printf '%s|%s|%s\n' "$APP_NAME" "${VERSION:-unknown}" "$latest"
            else
                print_warning "$APP_NAME: update available (${VERSION:-unknown} → $latest)"
            fi
        fi
    done

    if [ "$porcelain" = false ]; then
        if [ "$outdated" -eq 0 ] && [ "$failed" -eq 0 ]; then
            print_success "All external apps are up to date"
        elif [ "$outdated" -gt 0 ]; then
            print_info "Run './manage.sh apps update --all' (or update --name <app>) to update"
        fi
    fi
}

execute_update_from_source() {
    local lookup_name="$1"
    load_source_metadata "$lookup_name" || return 1
    local name="$APP_NAME" app_type="$APP_TYPE" repo="$SOURCE_REPO" pattern="$ASSET_PATTERN" installed="$VERSION"

    github_fetch_latest_release "$repo" || return 1

    if [ "$GH_RELEASE_TAG" = "$installed" ]; then
        print_info "$name is already up to date ($installed)"
        return 0
    fi
    print_info "Updating $name: ${installed:-unknown} → $GH_RELEASE_TAG"

    local type_filter="package"
    [ "$app_type" = "appimage" ] && type_filter="appimage"

    local asset_url=""
    asset_url=$(pick_release_asset "$pattern" "$type_filter" false) || return 1

    download_release_asset "$asset_url" || return 1
    local download_dir=""
    download_dir=$(dirname "$DOWNLOADED_ASSET_PATH")

    local rc=0
    if [ "$app_type" = "appimage" ]; then
        # Same name → same slug → replaces the AppImage + desktop entry in place
        execute_import_appimage "$DOWNLOADED_ASSET_PATH" "$name" || rc=1
    else
        # Reinstalls in the saved container; launch args are preserved
        execute_update_distrobox "$name" "$DOWNLOADED_ASSET_PATH" || rc=1
    fi
    rm -rf "$download_dir"

    if [ "$rc" -eq 0 ]; then
        save_source_metadata "$name" "$app_type" "$repo" "$pattern" "$GH_RELEASE_TAG"
        print_success "$name updated to $GH_RELEASE_TAG"
    fi
    return "$rc"
}

do_update_app() {
    local app_name="" update_all=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --name) app_name="$2"; shift 2 ;;
            --all) update_all=true; shift ;;
            --help|-h) usage; return 0 ;;
            *)
                if [ -z "$app_name" ]; then
                    app_name="$1"
                else
                    print_error "Unexpected argument: $1"
                    return 1
                fi
                shift ;;
        esac
    done

    if [ "$update_all" = true ]; then
        shopt -s nullglob
        local files=("$SOURCES_STATE_DIR"/*.env)
        shopt -u nullglob
        if [ ${#files[@]} -eq 0 ]; then
            print_info "No apps have an update source."
            return 0
        fi
        local file rc=0
        for file in "${files[@]}"; do
            APP_NAME=""
            # shellcheck disable=SC1090
            source "$file"
            execute_update_from_source "$APP_NAME" || rc=1
        done
        return "$rc"
    fi

    if [ -z "$app_name" ]; then
        print_error "update requires --name NAME or --all"
        usage
        return 1
    fi

    execute_update_from_source "$app_name"
}

interactive_install_github() {
    local repo_input=""
    repo_input=$(prompt_with_default "GitHub repo or releases URL" "" "owner/repo or https://github.com/owner/repo") || return 0
    [ -z "$repo_input" ] && return 0
    do_install_github "$repo_input"
}

interactive_set_source() {
    local app_name="$1"
    local repo_input=""
    repo_input=$(prompt_with_default "GitHub repo or releases URL" "" "owner/repo") || return 0
    [ -z "$repo_input" ] && return 0
    local version=""
    version=$(prompt_with_default "Currently installed version tag (optional, e.g. v4.6.2)" "" "Leave empty if unknown" false) || return 0
    execute_set_source "$app_name" "$repo_input" "" "$version"
}

interactive_check_updates() {
    ensure_dirs
    shopt -s nullglob
    local files=("$SOURCES_STATE_DIR"/*.env)
    shopt -u nullglob

    if [ ${#files[@]} -eq 0 ]; then
        print_info "No apps have an update source yet."
        print_info "Install via 'Install from GitHub release', or attach one to an installed app under 'Manage installed apps'."
        return 0
    fi

    local report=""
    spin_capture report "Checking ${#files[@]} app(s) for updates..." do_check_updates --porcelain || true

    if [ -z "$report" ]; then
        print_success "All external apps are up to date"
        return 0
    fi

    local -a labels=() names=()
    local name installed latest
    while IFS='|' read -r name installed latest; do
        [ -z "$name" ] && continue
        labels+=("$name ($installed → $latest)")
        names+=("$name")
    done <<< "$report"

    print_warning "${#names[@]} update(s) available"

    local selected=""
    if command_exists gum; then
        selected=$(printf '%s\n' "${labels[@]}" | gum choose --no-limit --cursor.foreground="212" \
            --header "Select apps to update (space to select, enter to confirm)") || return 0
    else
        printf '%s\n' "${labels[@]}"
        local answer=""
        read -r -p "Update all? [y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] && selected=$(printf '%s\n' "${labels[@]}")
    fi

    if [ -z "$selected" ]; then
        print_info "Nothing selected."
        return 0
    fi

    local line i
    while IFS= read -r line; do
        for i in "${!labels[@]}"; do
            if [ "${labels[$i]}" = "$line" ]; then
                execute_update_from_source "${names[$i]}" || true
                break
            fi
        done
    done <<< "$selected"
}

do_list() {
    ensure_dirs
    local found=false

    # List AppImages
    local -a appimages=()
    mapfile -t appimages < <(list_installed_appimages)
    if [ ${#appimages[@]} -gt 0 ]; then
        found=true
        local path
        for path in "${appimages[@]}"; do
            local slug src_field=""
            slug=$(basename "$path" .AppImage)
            if [ -f "$SOURCES_STATE_DIR/${slug}.env" ]; then
                src_field=$(SOURCE_REPO="" VERSION=""; source "$SOURCES_STATE_DIR/${slug}.env" \
                    && printf ' | source=%s | version=%s' "$SOURCE_REPO" "${VERSION:-unknown}")
            fi
            echo "$slug | type=appimage | path=$path$src_field"
        done
    fi

    # List managed Distrobox apps
    local -a _listed_ids=()
    shopt -s nullglob
    local files=("$DISTROBOX_STATE_DIR"/*.env)
    shopt -u nullglob
    if [ ${#files[@]} -gt 0 ]; then
        found=true
        local file
        for file in "${files[@]}"; do
            APP_ARGS=""
            # shellcheck disable=SC1090
            source "$file"
            _listed_ids+=("$APP_ID")
            local args_field=""
            [ -n "${APP_ARGS:-}" ] && args_field=" | args=$APP_ARGS"
            local src_file src_field=""
            src_file=$(source_file_for_name "$APP_NAME")
            if [ -f "$src_file" ]; then
                src_field=$(SOURCE_REPO="" VERSION=""; source "$src_file" \
                    && printf ' | source=%s | version=%s' "$SOURCE_REPO" "${VERSION:-unknown}")
            fi
            echo "$APP_NAME | type=distrobox | container=$CONTAINER | app=$APP_ID | pkg=$PACKAGE_TYPE$args_field$src_field"
        done
    fi

    # List unmanaged Distrobox apps (exported but no metadata)
    shopt -s nullglob
    local -a desktop_files=("$APP_DESKTOP_DIR"/*.desktop)
    shopt -u nullglob
    local df
    for df in "${desktop_files[@]}"; do
        grep -q 'distrobox-enter' "$df" 2>/dev/null || continue
        local df_basename
        df_basename=$(basename "$df")
        local already=false
        local mid
        for mid in "${_listed_ids[@]}"; do
            if [[ "$df_basename" == *"$mid"* || "$mid" == "$df_basename" ]]; then
                already=true
                break
            fi
        done
        [ "$already" = true ] && continue

        found=true
        local df_name df_container
        df_name=$(sed -n 's/^Name=//p' "$df" | head -1)
        df_container=$(sed -n 's/.*distrobox-enter.*-n \([^ ]*\).*/\1/p' "$df" | head -1)
        echo "${df_name:-$df_basename} | type=distrobox (unmanaged) | container=${df_container:-unknown} | file=$df"
    done

    if [ "$found" = false ]; then
        print_info "No managed apps found"
    fi
}

interactive_install_app() {
    local file_path=""
    file_path=$(pick_file_from_downloads "Pick an app to install" all) || return 0

    local file_lower="${file_path,,}"
    case "$file_lower" in
        *.appimage)
            interactive_import_appimage_with_file "$file_path"
            ;;
        *.deb|*.rpm|*.pkg.tar|*.pkg.tar.*)
            interactive_install_distrobox_with_file "$file_path"
            ;;
        *)
            print_error "Unsupported file type: $(basename "$file_path")"
            return 1
            ;;
    esac
}

interactive_manage_apps() {
    ensure_dirs

    # Build unified list of installed apps
    local -a app_labels=()
    local -a app_types=()
    local -a app_keys=()

    # Collect AppImages
    local -a appimages=()
    mapfile -t appimages < <(list_installed_appimages)
    local path
    for path in "${appimages[@]}"; do
        local name
        name=$(basename "$path" .AppImage)
        app_labels+=("$name [AppImage]")
        app_types+=("appimage")
        app_keys+=("$path")
    done

    # Collect managed Distrobox apps (with .env metadata)
    local -a _managed_app_ids=()
    shopt -s nullglob
    local -a meta_files=("$DISTROBOX_STATE_DIR"/*.env)
    shopt -u nullglob
    local file
    for file in "${meta_files[@]}"; do
        local _app_name _container _app_id
        # shellcheck disable=SC1090
        IFS=$'\t' read -r _app_name _container _app_id < <(
            source "$file" && printf '%s\t%s\t%s' "$APP_NAME" "$CONTAINER" "$APP_ID"
        )
        _managed_app_ids+=("$_app_id")
        app_labels+=("$_app_name [Distrobox: $_container]")
        app_types+=("distrobox")
        app_keys+=("$file")
    done

    # Discover distrobox-exported apps without metadata (installed manually)
    shopt -s nullglob
    local -a desktop_files=("$APP_DESKTOP_DIR"/*.desktop)
    shopt -u nullglob
    local df
    for df in "${desktop_files[@]}"; do
        # Only match desktop files that invoke distrobox-enter
        grep -q 'distrobox-enter' "$df" 2>/dev/null || continue

        local df_basename
        df_basename=$(basename "$df")

        # Skip if already tracked by metadata
        local already_managed=false
        local mid
        for mid in "${_managed_app_ids[@]}"; do
            if [[ "$df_basename" == *"$mid"* || "$mid" == "$df_basename" ]]; then
                already_managed=true
                break
            fi
        done
        [ "$already_managed" = true ] && continue

        # Extract name and container from the desktop file
        local df_name df_container
        df_name=$(sed -n 's/^Name=//p' "$df" | head -1)
        df_container=$(sed -n 's/.*distrobox-enter.*-n \([^ ]*\).*/\1/p' "$df" | head -1)
        [ -z "$df_name" ] && df_name="$df_basename"
        [ -z "$df_container" ] && df_container="unknown"

        app_labels+=("$df_name [Distrobox: $df_container] (unmanaged)")
        app_types+=("distrobox-unmanaged")
        app_keys+=("$df")
    done

    if [ ${#app_labels[@]} -eq 0 ]; then
        print_info "No installed apps found"
        return 0
    fi

    # Pick an app
    local selection=""
    local selected_index=-1

    if command_exists gum; then
        selection=$(printf '%s\n' "${app_labels[@]}" | gum filter --header "Manage installed apps" --placeholder "Type to search...") || return 0
    else
        echo "Installed apps:"
        local i
        for i in "${!app_labels[@]}"; do
            echo "  $((i + 1))) ${app_labels[$i]}"
        done
        local choice
        read -r -p "Choose [1-${#app_labels[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#app_labels[@]} ]; then
            selection="${app_labels[$((choice - 1))]}"
        else
            print_info "Cancelled."
            return 0
        fi
    fi

    # Find the selected index
    local idx
    for idx in "${!app_labels[@]}"; do
        if [ "${app_labels[$idx]}" = "$selection" ]; then
            selected_index=$idx
            break
        fi
    done

    if [ "$selected_index" -lt 0 ]; then
        print_error "Selection not found"
        return 1
    fi

    local app_type="${app_types[$selected_index]}"
    local app_key="${app_keys[$selected_index]}"

    # Does this app have a saved GitHub release source?
    local source_file=""
    if [ "$app_type" = "appimage" ]; then
        source_file="$SOURCES_STATE_DIR/$(basename "$app_key" .AppImage).env"
    elif [ "$app_type" = "distrobox" ]; then
        source_file="$SOURCES_STATE_DIR/$(basename "$app_key")"
    fi
    local has_source=false
    [ -n "$source_file" ] && [ -f "$source_file" ] && has_source=true

    # Pre-extract unmanaged distrobox info (used by both Update and Uninstall)
    local um_name="" um_container="" um_app_id=""
    if [ "$app_type" = "distrobox-unmanaged" ]; then
        um_name=$(sed -n 's/^Name=//p' "$app_key" | head -1)
        um_container=$(sed -n 's/.*distrobox-enter.*-n \([^ ]*\).*/\1/p' "$app_key" | head -1)
        # Host desktop file is named ${container}-${app_id}, strip the container prefix
        local _host_basename
        _host_basename=$(basename "$app_key")
        um_app_id="${_host_basename#"${um_container}-"}"
    fi

    # Pick an action
    local action=""
    if [ "$app_type" = "distrobox-unmanaged" ]; then
        if command_exists gum; then
            action=$(gum choose "Update (adopt)" "Uninstall" "Cancel") || return 0
        else
            echo "1) Update (adopt)"
            echo "2) Uninstall"
            echo "3) Cancel"
            local achoice
            read -r -p "Choose [1-3]: " achoice
            case "$achoice" in
                1) action="Update (adopt)" ;;
                2) action="Uninstall" ;;
                *) action="Cancel" ;;
            esac
        fi
    else
        local -a actions=()
        if [ "$has_source" = true ]; then
            actions+=("Update from GitHub" "Update from local file")
        else
            actions+=("Update from local file" "Set GitHub update source")
        fi
        actions+=("Uninstall" "Cancel")

        if command_exists gum; then
            action=$(gum choose "${actions[@]}") || return 0
        else
            local i achoice
            for i in "${!actions[@]}"; do
                echo "$((i + 1))) ${actions[$i]}"
            done
            read -r -p "Choose [1-${#actions[@]}]: " achoice
            if [[ "$achoice" =~ ^[0-9]+$ ]] && [ "$achoice" -ge 1 ] && [ "$achoice" -le ${#actions[@]} ]; then
                action="${actions[$((achoice - 1))]}"
            else
                action="Cancel"
            fi
        fi
    fi

    case "$action" in
        "Update (adopt)")
            # Adopt an unmanaged distrobox app: pick a package, update, and save metadata
            local package_path=""
            package_path=$(pick_file_from_downloads "Pick the package to install" package) || return 0

            local pkg_type=""
            pkg_type=$(package_type_for_file "$package_path") || return 0

            local app_name=""
            app_name=$(prompt_with_default "App name" "$um_name" "Saved app name") || return 0

            if ! confirm_summary "Adopt & update Distrobox app" \
                "  App: $app_name" \
                "  Container: $um_container" \
                "  Desktop entry: $um_app_id" \
                "  Package: $package_path" \
                "  Type: $pkg_type"; then
                print_info "Cancelled."
                return 0
            fi

            install_package_in_distrobox "$um_container" "$package_path" "$pkg_type" || {
                print_error "Package install failed."
                return 1
            }
            # Skip re-export: app is already exported and may have custom flags in its desktop file
            save_distrobox_metadata "$app_name" "$um_container" "$pkg_type" "$um_app_id"
            print_success "Adopted and updated Distrobox app"
            echo "  App: $app_name"
            echo "  Container: $um_container"
            echo "  Desktop entry: $um_app_id"
            ;;
        "Update from GitHub")
            local src_name=""
            src_name=$(APP_NAME=""; source "$source_file" && printf '%s' "$APP_NAME")
            execute_update_from_source "${src_name:-$(basename "$source_file" .env)}"
            ;;
        "Set GitHub update source")
            local target_name=""
            if [ "$app_type" = "appimage" ]; then
                target_name=$(basename "$app_key" .AppImage)
            else
                target_name=$(APP_NAME=""; source "$app_key" && printf '%s' "$APP_NAME")
            fi
            interactive_set_source "$target_name"
            ;;
        "Update from local file")
            if [ "$app_type" = "appimage" ]; then
                local current_name
                current_name=$(basename "$app_key" .AppImage)
                local new_file=""
                new_file=$(pick_file_from_downloads "Pick the updated AppImage" appimage) || return 0
                interactive_import_appimage_with_file "$new_file" "$current_name"
            else
                APP_ARGS=""
                # shellcheck disable=SC1090
                source "$app_key"
                APP_ARGS="${APP_ARGS:-}"
                local package_path=""
                package_path=$(pick_file_from_downloads "Pick the updated package" package) || return 0

                local new_package_type=""
                new_package_type=$(package_type_for_file "$package_path") || return 0
                local type_warning=""
                if [ "$new_package_type" != "$PACKAGE_TYPE" ]; then
                    type_warning="  Warning: saved type $PACKAGE_TYPE, new file looks like $new_package_type"
                fi

                if ! confirm_summary "Update Distrobox app" \
                    "  App: $APP_NAME" \
                    "  Container: $CONTAINER" \
                    "  Desktop entry: $APP_ID" \
                    "  Launch args: ${APP_ARGS:-none}" \
                    "  New package: $package_path" \
                    "${type_warning:-  Package type matches saved metadata}"; then
                    print_info "Cancelled."
                    return 0
                fi

                install_package_in_distrobox "$CONTAINER" "$package_path" "$new_package_type" || {
                    print_error "Package update failed."
                    return 1
                }
                export_distrobox_app "$CONTAINER" "$APP_ID" || {
                    print_error "Export refresh failed."
                    return 1
                }
                apply_distrobox_app_args "$APP_ID" "$CONTAINER" "$APP_ARGS"
                save_distrobox_metadata "$APP_NAME" "$CONTAINER" "$new_package_type" "$APP_ID" "$APP_ARGS"
                print_success "Updated Distrobox app"
                echo "  App: $APP_NAME"
                echo "  Container: $CONTAINER"
                echo "  Desktop entry: $APP_ID"
                [ -n "$APP_ARGS" ] && echo "  Launch args: $APP_ARGS"
            fi
            ;;
        "Uninstall")
            if [ "$app_type" = "appimage" ]; then
                if ! confirm_summary "Remove AppImage" \
                    "  AppImage: $app_key"; then
                    print_info "Cancelled."
                    return 0
                fi
                execute_remove_appimage "$app_key"
            elif [ "$app_type" = "distrobox-unmanaged" ]; then
                if ! confirm_summary "Remove Distrobox app (unmanaged)" \
                    "  App: $um_name" \
                    "  Container: $um_container" \
                    "  Desktop file: $app_key"; then
                    print_info "Cancelled."
                    return 0
                fi

                if [ -n "$um_container" ]; then
                    print_info "Removing exported app '$um_app_id' from container '$um_container'..."
                    run_in_distrobox "$um_container" distrobox-export --delete --app "$um_app_id" 2>/dev/null || true
                fi
                rm -f "$app_key"
                refresh_desktop_db
                print_success "Removed Distrobox app"
                echo "  App: $um_name"
                echo "  Container: $um_container"
            else
                # shellcheck disable=SC1090
                source "$app_key"
                if ! confirm_summary "Remove Distrobox app" \
                    "  App: $APP_NAME" \
                    "  Container: $CONTAINER" \
                    "  Desktop entry: $APP_ID"; then
                    print_info "Cancelled."
                    return 0
                fi
                execute_remove_distrobox "$app_key"
            fi
            ;;
        *)
            print_info "Cancelled."
            return 0
            ;;
    esac
}

main_menu() {
    while true; do
        local action=""

        if command_exists gum; then
            action=$(gum choose \
                "Install app (local file)" \
                "Install from GitHub release" \
                "Manage installed apps" \
                "Check for updates" \
                "Cancel") || action="Cancel"
        else
            echo "1) Install app (local file)"
            echo "2) Install from GitHub release"
            echo "3) Manage installed apps"
            echo "4) Check for updates"
            echo "5) Cancel"
            read -r -p "Choose an option [1-5]: " choice
            case "$choice" in
                1) action="Install app (local file)" ;;
                2) action="Install from GitHub release" ;;
                3) action="Manage installed apps" ;;
                4) action="Check for updates" ;;
                *) action="Cancel" ;;
            esac
        fi

        case "$action" in
            "Install app (local file)")
                interactive_install_app || true
                ;;
            "Install from GitHub release")
                interactive_install_github || true
                ;;
            "Manage installed apps")
                interactive_manage_apps || true
                ;;
            "Check for updates")
                interactive_check_updates || true
                ;;
            *)
                print_info "Cancelled."
                return 0
                ;;
        esac
    done
}

case "${1:-}" in
    import-appimage)
        shift
        do_import_appimage "$@"
        ;;
    remove-appimage)
        shift
        do_remove_appimage "$@"
        ;;
    install-distrobox)
        shift
        do_install_distrobox "$@"
        ;;
    update-distrobox)
        shift
        do_update_distrobox "$@"
        ;;
    install-github)
        shift
        do_install_github "$@"
        ;;
    set-source)
        shift
        do_set_source "$@"
        ;;
    check-updates)
        shift
        if [ "${1:-}" = "--interactive" ]; then
            interactive_check_updates
        else
            do_check_updates "$@"
        fi
        ;;
    update)
        shift
        do_update_app "$@"
        ;;
    list)
        do_list
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        main_menu
        ;;
esac
