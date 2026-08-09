#!/bin/bash
# Common utility functions

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Every status tag pads to the width of the longest — [SUCCESS] and [WARNING], at
# 9 — so the message text starts in the same column whatever the level. A log is
# read down the message column, and unpadded tags step that column in and out by
# up to three characters on every line.
TAG_WIDTH=9

# The width applies to the bare tag: the colour is a separate `%b` conversion, so
# its escape bytes never count towards the field. (They would if colour and tag
# were one argument to one field — then the width is spent on the escapes and no
# padding is emitted at all.)
#
# `%s` for the message, not `echo -e`'s implicit unescaping — which switching to
# printf for the field width is what makes possible in the first place. Nothing
# should reinterpret a backslash that arrived in a path or a command's output.
_print_tag() {
    local color="$1" tag="$2" msg="$3"
    printf '%b%-*s%b %s\n' "$color" "$TAG_WIDTH" "$tag" "$NC" "$msg"
}

# Print colored messages
print_info() {
    _print_tag "$BLUE" "[INFO]" "$1"
}

print_success() {
    _print_tag "$GREEN" "[SUCCESS]" "$1"
}

print_warning() {
    _print_tag "$YELLOW" "[WARNING]" "$1"
}

# Print warning and track it for the end-of-install summary
track_warning() {
    print_warning "$1"
    INSTALL_WARNINGS+=("$1")
}

# ── Package shortfall ────────────────────────────────────────────────────────
# Set for the rest of the run by anything that leaves this machine without a
# package the repo declares — a failed install, a declined one, a custom entry
# that did not land. record_synced_state consults it and will not stamp the
# anchor while it is set.
#
# One flag rather than a judgement per command, because the two commands that
# install packages had drawn opposite conclusions from the same situation:
# `dots update` grew its own flag for exactly this and held the anchor back,
# while `dots setup` stamped it regardless of a "Some base packages failed to
# install" warning — so packages that failed during setup were never offered
# again by any later delta. Marking it where the shortfall happens, and reading
# it in the single writer of the anchor, is what makes the two agree.
#
# Per-process and deliberately not persisted: it describes this run, and the next
# run that installs everything it was asked to has no shortfall to report.
#
# Assigned only when already unset, because common.sh is sourced more than once in
# a run: installer.sh re-sources it through lib/services.sh *after* the package
# phase, and a plain `SYNC_SHORTFALL=false` there wiped what the installs had
# recorded, so `dots setup` stamped the anchor over a package that never landed —
# the exact failure this flag exists to prevent. Exported so a child that installs
# on our behalf inherits the outstanding shortfall; the value cannot travel back up
# from a child, which is why the two callers that delegate an install to one read
# its exit status instead.
: "${SYNC_SHORTFALL:=false}"
export SYNC_SHORTFALL

mark_sync_shortfall() {
    SYNC_SHORTFALL=true
    export SYNC_SHORTFALL
}

sync_shortfall() {
    $SYNC_SHORTFALL
}

print_error() {
    _print_tag "$RED" "[ERROR]" "$1"
}

# One presentation for "the user stopped this", shared by the signal trap below
# and by prompts that learn of an abort from an exit status rather than a signal.
abort_interrupted() {
    echo
    print_warning "Interrupted."
    exit 130
}

# Install a SIGINT/SIGTERM trap so Ctrl+C stops the script even when the child it
# is waiting on absorbs the signal and exits *normally* rather than dying from it.
# gum does exactly that (it exits 130), and bash only exits on its own when the
# foreground command was killed by the signal — so a shell with no trap simply
# carries on to the next command, which for a prompt means carrying on with an
# answer the user never gave.
#
# Every shell gets a trap. What used to happen: the marker below is exported, and
# any shell that found it set skipped installing one — which meant *no script dots
# runs ever had a trap*, since `dots` itself installs the first one and `dots
# update`, `dots packages` and `dots backup` are all its children. An interrupt at
# one of their gum prompts was read as a plain answer and the flow continued to the
# end, applying the dotfiles the user had just tried to stop.
#
# The marker survives for what it was actually good for — keeping the announcement
# to one line. An inner shell stops silently and lets the outermost one, whose trap
# runs once the child has exited, do the talking. tools/manage-external-apps.py
# reads the same marker for the same reason.
install_interrupt_trap() {
    if [ -n "${_INTERRUPT_TRAP_OWNER:-}" ]; then
        trap 'exit 130' INT TERM
        return 0
    fi
    export _INTERRUPT_TRAP_OWNER=$$
    trap abort_interrupted INT TERM
}

# `gum confirm` for a question where declining and aborting are different
# answers. gum exits 0 for yes, 1 for no and 130 when cancelled — and cancelling
# with Esc sends no signal at all, so the interrupt trap never fires and Esc
# otherwise reads as a deliberate "no", quietly carrying on with the rest of a
# flow the user meant to stop. Ctrl+C is still delivered as a signal and handled
# by the trap; this covers the same intent expressed the other way.
#
# Returns 0 for yes and 1 for no. Never returns on an abort. Requires gum — a
# caller that cannot assume it must check first, since gum's absence would come
# back as some other status and be read as "no".
confirm_or_abort() {
    local rc=0
    gum confirm "$@" || rc=$?
    [ "$rc" -eq 130 ] && abort_interrupted
    return "$rc"
}

# `gum choose` for a picker where cancelling means "stop", assigning the choice to
# the variable named by the first argument. Returns 0 with a selection, 1 when the
# user chose nothing, and never returns on a cancel.
#
# The output goes through a variable name — the shape spin_capture already uses —
# rather than stdout, and that is the whole reason this can exist. A helper whose
# output is captured (`sel=$(… | choose_or_abort …)`) runs inside a command
# substitution, which is a subshell, so its `exit` would end only the subshell and
# leave the caller running with an empty selection and no idea why. Feed the
# options in on stdin with a redirect, NOT a pipe, for the same reason: the right
# side of a pipe is also a subshell.
# Usage: choose_or_abort picked --no-limit --header "…" <<< "$options"
choose_or_abort() {
    local __var="$1"
    shift
    local __out __rc=0
    __out=$(gum choose "$@") || __rc=$?
    [ "$__rc" -eq 130 ] && abort_interrupted
    printf -v "$__var" '%s' "$__out"
    [ -n "$__out" ] || return 1
    return 0
}

# Test whether a group is in SELECTED_GROUP_NAMES.
group_selected() {
    [[ " ${SELECTED_GROUP_NAMES[*]} " == *" $1 "* ]]
}

# True when a custom_install entry survived the selector: its group is selected,
# and either the whole group was taken or the entry was kept in the custom list.
#
# `grep -qxF`, not the `case " $list " in *" name "*` glob this replaces — the
# selector joins kept entries with newlines, so only a single-entry list ever has
# spaces around its one name. vibewatch was the sole user and the ai group has
# exactly one custom entry, which is why it went unnoticed; messaging has two, so
# the second always read as unticked.
custom_entry_selected() {
    local group="$1" entry="$2"
    group_selected "$group" || return 1
    [ "${GROUP_PACKAGE_MODE[$group]:-all}" = "custom" ] || return 0
    grep -qxF "$entry" <<< "${GROUP_CUSTOM_PACKAGE_LIST[$group]:-}"
}

print_header() {
    echo ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}  $1${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Verify required commands exist; report every missing one at once.
# Usage: require_tools age tar git || return 1
require_tools() {
    local missing=() tool
    for tool in "$@"; do
        command_exists "$tool" || missing+=("$tool")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing[*]}"
        print_info "Install with: sudo pacman -S ${missing[*]}"
        return 1
    fi
}

# Source the distro-family helpers for this machine, or fail with a message.
# Requires $DOTFILES_DIR set and lib/detect.sh already sourced; leaves DISTRO
# and DISTRO_FAMILY set for callers that branch on them. Every tool entry point
# needs exactly this, so the detect-then-source dance lives here, not in each one.
load_distro_lib() {
    DISTRO=$(detect_distro)
    DISTRO_FAMILY=$(get_distro_family "$DISTRO")

    local lib="$DOTFILES_DIR/install/distros/$DISTRO_FAMILY.sh"
    if [ ! -f "$lib" ]; then
        print_error "Unsupported distribution family: $DISTRO_FAMILY"
        return 1
    fi
    source "$lib"
}

# Escape a string for embedding in a JSON string literal.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# ── Spinners ─────────────────────────────────────────────────────────────────
# A single, consistent loader for silent multi-second work (catalogue builds,
# downloads, extraction). Do NOT wrap commands that print their own progress
# (pacman/apt/dnf, curl install scripts, chezmoi apply) — that hides output the
# user needs to see. gum draws the spinner on stderr, so it still animates when
# stdout is captured (e.g. inside `$(...)`); we gate on stderr being a TTY and
# otherwise run the command plainly. set -e safe: the command's exit status is
# captured, never left as a bare failing command.

# Core: run "$@" with stdout redirected to OUTFILE while a spinner titled TITLE
# shows, then return the command's exit status. Works for shell functions and
# external commands alike (the command runs in a background job we poll).
_spin_core() {
    local title="$1" outfile="$2"
    shift 2
    local rc=0
    if command_exists gum && [ -t 2 ]; then
        ( "$@" >"$outfile" 2>/dev/null ) &
        local pid=$!
        gum spin --spinner dot --title "$title" -- \
            bash -c "while kill -0 ${pid} 2>/dev/null; do sleep 0.1; done" || true
        wait "$pid" || rc=$?
    else
        "$@" >"$outfile" 2>/dev/null || rc=$?
    fi
    return "$rc"
}

# Capture CMD's stdout into the variable named VAR while showing a spinner.
# Usage: spin_capture result "Loading packages..." build_json arg1 arg2
spin_capture() {
    local __var="$1" __title="$2"
    shift 2
    local __tmp __rc=0
    __tmp=$(mktemp)
    _spin_core "$__title" "$__tmp" "$@" || __rc=$?
    printf -v "$__var" '%s' "$(cat "$__tmp")"
    rm -f "$__tmp"
    return "$__rc"
}

# Run CMD (output discarded) while showing a spinner; returns CMD's exit status.
# Usage: spin_run "Cloning theme..." git clone --depth 1 "$repo" "$dest"
spin_run() {
    local __title="$1"
    shift
    _spin_core "$__title" /dev/null "$@"
}

# Wait for a keypress before returning to a menu, so the output the user just
# produced isn't immediately scrolled away by the menu redraw.
pause_for_user() {
    echo ""
    read -rsn1 -p "Press any key to continue..."
    echo ""
}

# Get the script directory
get_script_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# Get the dotfiles root directory
get_dotfiles_dir() {
    local script_dir
    script_dir="$(get_script_dir)"
    # Go up two levels from install/lib to get to dotfiles root
    cd "$script_dir/../.." && pwd
}

# Parse YAML file and extract package list for a distro
# Usage: parse_packages "file.yaml" "arch"
parse_yaml_nested_list() {
    local file="$1" parent="$2" child="$3"

    if command_exists yq; then
        # grep exits non-zero when a section has no matching lines; tolerate it so
        # callers running under `set -o pipefail` don't abort on an empty section.
        yq -r ".${parent}.${child}[]? // \"\"" "$file" 2>/dev/null \
            | grep -v "^#" | grep -v '^[[:space:]]*$' || true
    else
        local in_parent=false in_child=false line
        while IFS= read -r line; do
            if [[ "$line" =~ ^${parent}:[[:space:]]*$ ]]; then
                in_parent=true; in_child=false; continue
            fi
            if $in_parent; then
                # Any other top-level key ends the parent block.
                [[ "$line" =~ ^[a-z] ]] && break
                if [[ "$line" =~ ^[[:space:]]+${child}:[[:space:]]*$ ]]; then
                    in_child=true; continue
                fi
                if $in_child; then
                    # A sibling section at the same level ends this one.
                    if [[ "$line" =~ ^[[:space:]]+[a-z_]+:[[:space:]]*$ ]]; then
                        in_child=false; continue
                    fi
                    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.+)$ ]]; then
                        echo "${BASH_REMATCH[1]}" | sed 's/#.*//' | xargs
                    fi
                fi
            fi
        done < "$file"
    fi
}

# Packages for a distro/section — `packages.<name>`.
#
# Anchored on the `packages:` parent rather than matching the section name
# wherever it appears, which is what this fallback used to do. base.yaml now
# carries both `packages.desktop` and `services.desktop`, and a bare
# `^\s*desktop:` match cannot tell those apart — it would have handed the package
# list back as the service list, on exactly the machines that have no yq.
parse_packages() {
    parse_yaml_nested_list "$1" packages "$2"
}

# Parse YAML descriptions map and output "package=description" lines
# Usage: parse_descriptions "file.yaml"
parse_descriptions() {
    local file="$1"

    if command_exists yq; then
        yq -r '.descriptions // {} | to_entries[] | .key + "=" + .value' "$file" 2>/dev/null
    else
        # Fallback: simple grep-based parsing
        local in_section=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^descriptions:[[:space:]]*$ ]]; then
                in_section=true
                continue
            fi
            if $in_section; then
                # Exit when hitting another top-level key
                if [[ "$line" =~ ^[a-z] ]]; then
                    break
                fi
                # Match "  package_name: some description"
                if [[ "$line" =~ ^[[:space:]]+([^:]+):[[:space:]]+(.+)$ ]]; then
                    local pkg="${BASH_REMATCH[1]}"
                    local desc="${BASH_REMATCH[2]}"
                    # Strip surrounding quotes if present
                    desc="${desc#\"}"
                    desc="${desc%\"}"
                    desc="${desc#\'}"
                    desc="${desc%\'}"
                    echo "${pkg}=${desc}"
                fi
            fi
        done < "$file"
    fi
}

# Read a top-level YAML list — a `key:` header followed by `- item` lines — and
# emit one item per line, blanks dropped.
#
# One parser for every such list in the schema, because the fallback below is
# precisely the part that drifts. It existed in three hand-copied versions, and
# only the desktop_only one ever learned to strip an inline comment: on a machine
# without yq, `- vicinae.service  # the launcher` parsed correctly as a
# desktop_only entry and yielded a unit name with the comment glued on as a
# service. The yq path never had that bug, so it would only ever have shown up on
# the fallback nobody tests.
#
# The named wrappers below are the API — call those. A bare key at a call site is
# how `services` and `user_services` get confused, and those two must not be:
# one is enabled with sudo and the other must never see it, since
# `sudo systemctl --user` talks to root's instance rather than the caller's.
parse_yaml_list() {
    local file="$1" key="$2"

    if command_exists yq; then
        # No comment handling needed here — yq is a real YAML parser and has
        # already dropped them. `// ""` turns a null entry into an empty line,
        # which is what the grep removes; `|| true` because grep exits non-zero
        # when it filters everything out, and callers run under `set -e`.
        yq -r ".${key}[]? // \"\"" "$file" 2>/dev/null | grep -v '^[[:space:]]*$' || true
    else
        local in_section=false line
        while IFS= read -r line; do
            if [[ "$line" =~ ^${key}:[[:space:]]*$ ]]; then
                in_section=true
                continue
            fi
            if $in_section; then
                # Any other top-level key ends the list.
                [[ "$line" =~ ^[a-z] ]] && break
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.+)$ ]]; then
                    # xargs trims; it also prints nothing for a line that was
                    # only a comment, so no blank survives the strip.
                    echo "${BASH_REMATCH[1]}" | sed 's/#.*//' | xargs
                fi
            fi
        done < "$file"
    fi
}

# The declared lists, one wrapper each. Adding a list to the schema means adding
# a line here, not another copy of the loop above.
parse_dotfiles()      { parse_yaml_list "$1" dotfiles; }
parse_services()      { parse_yaml_list "$1" services; }
parse_user_services() { parse_yaml_list "$1" user_services; }
parse_desktop_only()  { parse_yaml_list "$1" desktop_only; }


# Read a group's declared hardware requirement (the `requires_hardware:` field),
# or empty when none is declared. This is a single top-level scalar, so we grep
# it directly rather than spawning yq — it runs once per group during the
# pre-selection scan, where yq's startup cost is otherwise visible.
# Usage: parse_requires_hardware "file.yaml"
parse_requires_hardware() {
    local file="$1"
    local val
    val=$(grep -m1 '^requires_hardware:' "$file" 2>/dev/null \
        | sed 's/^requires_hardware:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]*$//')
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    printf '%s' "$val"
}

# Whether the hardware a group requires is present. Groups without a
# `requires_hardware:` field (or with an unrecognised value) are always
# available. This is the single gate the installer and the package manager
# both consult, so hardware-specific groups (e.g. biometric → fingerprint
# reader) appear in exactly the same machines everywhere.
# Usage: group_hardware_available "file.yaml"  (returns 0 = available)
group_hardware_available() {
    local file="$1"
    local req
    req=$(parse_requires_hardware "$file")
    case "$req" in
        "" | none)   return 0 ;;
        fingerprint) has_fingerprint_reader ;;
        *)           return 0 ;;
    esac
}

# ── Entry sections ───────────────────────────────────────────────────────────
# `custom_install:` (group files) and `tools:` (common.yaml) are the same shape
# — a list of maps keyed by `name` under a top-level key — so one parser family
# serves both, taking the section as an argument. Each entry's fields are
# documented where the yaml declares them (packages/common.yaml).

# Names of every entry in a section, one per line.
# Usage: parse_entry_names "file.yaml" "custom_install"
parse_entry_names() {
    local file="$1" section="$2"

    if command_exists yq; then
        yq -r "(.${section} // [])[].name" "$file" 2>/dev/null | grep -v "^$" || true
    else
        # Fallback: simple parsing
        local in_section=false line
        while IFS= read -r line; do
            if [[ "$line" =~ ^${section}:[[:space:]]*$ ]]; then
                in_section=true
                continue
            fi
            if $in_section; then
                # Exit when hitting another top-level key
                [[ "$line" =~ ^[a-z] ]] && break
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.+)$ ]]; then
                    echo "${BASH_REMATCH[1]}"
                fi
            fi
        done < "$file"
    fi
}

# One field of one entry, empty when unset.
# Usage: parse_entry_field "file.yaml" "custom_install" "claude-code" "install"
parse_entry_field() {
    local file="$1" section="$2" name="$3" field="$4"

    if command_exists yq; then
        yq -r "(.${section} // [])[] | select(.name == \"$name\") | .${field} // \"\"" "$file" 2>/dev/null
    else
        local in_section=false found=false line
        while IFS= read -r line; do
            if [[ "$line" =~ ^${section}:[[:space:]]*$ ]]; then
                in_section=true
                continue
            fi
            if $in_section; then
                [[ "$line" =~ ^[a-z] ]] && break
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*${name}[[:space:]]*$ ]]; then
                    found=true
                    continue
                fi
                if $found && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
                    break
                fi
                if $found && [[ "$line" =~ ^[[:space:]]*${field}:[[:space:]]*(.+)$ ]]; then
                    _unquote_yaml_scalar "${BASH_REMATCH[1]}"
                    return 0
                fi
            fi
        done < "$file"
    fi
}

# Strip the quotes off a YAML scalar, so the fallback parser returns what yq
# would. Without this a quoted value comes back with its quotes attached and
# eval'ing it looks for a command literally named `'[ -x "$HOME/..." ]'`.
_unquote_yaml_scalar() {
    local value="$1"
    if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
    fi
    printf '%s\n' "$value"
}

# Several fields of one entry in a single yq call — reading them one at a time
# costs a yq process per field, which dominates a whole-repo scan.
#
# Values are joined with $YAML_FIELD_SEP (Unit Separator) rather than newlines
# because the command-bearing fields hold multi-line shell snippets. A trailing
# empty field absorbs yq's final newline, so no real value picks it up; split it
# off with `mapfile -d "$YAML_FIELD_SEP" -t` and ignore the last element.
# Usage: mapfile -d "$YAML_FIELD_SEP" -t f \
#            < <(parse_entry_fields common.yaml tools eza binary source)
YAML_FIELD_SEP=$'\x1f'
parse_entry_fields() {
    local file="$1" section="$2" name="$3"
    shift 3
    local field

    if command_exists yq; then
        local list=""
        for field in "$@"; do
            list+="(.${field} // \"\" | tostring),"
        done
        yq -r "(.${section} // [])[] | select(.name == \"$name\") | [${list}\"\"] | join(\"$YAML_FIELD_SEP\")" \
            "$file" 2>/dev/null
    else
        for field in "$@"; do
            printf '%s%s' "$(parse_entry_field "$file" "$section" "$name" "$field")" "$YAML_FIELD_SEP"
        done
        echo ""
    fi
}

# Every value of one field across a section, one per line, skipping entries that
# don't declare it. A query rather than a name loop: reading the field per entry
# costs a yq process each, and callers want the whole column.
# Usage: parse_entry_field_values "common.yaml" "tools" "npm"
parse_entry_field_values() {
    local file="$1" section="$2" field="$3"

    if command_exists yq; then
        yq -r "(.${section} // [])[] | select(.${field}) | .${field}" "$file" 2>/dev/null \
            | grep -v "^$" || true
    else
        local name value
        while IFS= read -r name; do
            value=$(parse_entry_field "$file" "$section" "$name" "$field")
            if [ -n "$value" ]; then printf '%s\n' "$value"; fi
        done < <(parse_entry_names "$file" "$section")
    fi
}

parse_custom_install_names() { parse_entry_names "$1" "custom_install"; }

# Names of the custom_install entries in this file that declare `chezmoi_flag:
# true` — the ones that own an `install_<name>` chezmoi data key on top of the
# group flag.
#
# The key exists because a few custom entries are not only *installed*: their
# real payload is chezmoi-managed (vibewatch's waybar pill and Claude hook, the
# two chat shells' launchers, .desktop files and icons). Unticking one of those
# in the selector has to reach those files, which only a chezmoi flag can do.
#
# Declared in the yaml rather than listed in the installer, for exactly the
# reason the group-flag loop carries: a hand-kept list there is how `biometric`
# and `security` came to be installed on a machine whose chezmoi data recorded
# no flag for either. One flag per declaring entry, generated.
parse_custom_install_flag_entries() {
    local file="$1" name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ "$(parse_entry_field "$file" custom_install "$name" chezmoi_flag)" = "true" ] \
            && printf '%s\n' "$name"
    done < <(parse_custom_install_names "$file")
    return 0
}
parse_custom_install_cmd() { parse_entry_field "$1" "custom_install" "$2" "install"; }
parse_custom_install_check() { parse_entry_field "$1" "custom_install" "$2" "check"; }
parse_custom_install_requires() { parse_entry_field "$1" "custom_install" "$2" "requires"; }

# Run an entry's `check` command. Only the exit code matters: stdin is detached
# and all output silenced so a misbehaving check (one that launches an app or
# reads stdin) can't hang a scan or bleed text into a captured stdout stream.
# An entry with no check counts as not installed.
run_entry_check() {
    local check_cmd="$1"
    [ -n "$check_cmd" ] && eval "$check_cmd" </dev/null >/dev/null 2>&1
}

is_custom_install_installed() {
    run_entry_check "$(parse_custom_install_check "$1" "$2")"
}

# A `custom_install` entry brings its own `install_cmd` and no counterpart, so
# no caller can uninstall one — every removal path can only say so and move on.
#
# Says it in one place because three of them were saying it in three different
# wordings ("must be removed manually", "can't be auto-removed", "have no
# uninstall step"), which reads as three separate rules rather than one repeated
# fact, and would have to be found three times to change. If these entries ever
# gain an `uninstall_cmd`, this is the single function that stops being right.
warn_custom_uninstall() {
    [ $# -gt 0 ] || return 0
    print_warning "Custom-installed, no uninstall step ($#):"
    printf '  %s\n' "$@"
    print_info "  Remove them by hand if you want them gone"
}

# ── Node toolchain ───────────────────────────────────────────────────────────

# Where fnm's installer (--skip-shell) drops the binary. Not on a script's PATH,
# and the shell hook that would add it only runs for interactive shells.
FNM_BIN_DIR="$HOME/.local/share/fnm"

# Put the fnm-managed Node on PATH for the current shell. Installs nothing: a
# missing fnm just leaves node/npm absent, which callers report as unavailable.
# Idempotent — safe to call from several places in one run.
activate_fnm_node() {
    case ":$PATH:" in
        *":$FNM_BIN_DIR:"*) ;;
        *) [ -d "$FNM_BIN_DIR" ] && export PATH="$FNM_BIN_DIR:$PATH" ;;
    esac

    if command_exists fnm; then
        eval "$(fnm env --use-on-cd --shell bash 2>/dev/null)" || true
        hash -r 2>/dev/null || true
    fi
    return 0
}

# Where a global npm package lands: inside the Node version's own tree, reached
# through fnm's `default` alias. That is why moving Node strands every one of
# them — the new version starts with an empty node_modules. The path is stable
# while what it points at moves, which is what lets one constant name both the
# version being left and the one being landed on.
FNM_GLOBALS_DIR="$FNM_BIN_DIR/aliases/default/lib/node_modules"

# The global packages installed against the Node currently in use, one name per
# line, ready to hand back to `npm install -g`. npm and corepack ship with Node
# itself, so they are never ours to reinstall.
#
# A scope directory is not a package — its children are, so the two depths are
# globbed separately rather than walked and then descended into. Trimming the
# root off the whole path, instead of taking the basename, is what makes a scoped
# entry come back out as `@scope/name`.
list_global_npm_packages() {
    local path name
    [ -d "$FNM_GLOBALS_DIR" ] || return 0

    for path in "$FNM_GLOBALS_DIR"/[^@]* "$FNM_GLOBALS_DIR"/@*/*; do
        [ -d "$path" ] || continue
        name="${path#"$FNM_GLOBALS_DIR"/}"
        case "$name" in npm|corepack) continue ;; esac
        printf '%s\n' "$name"
    done
    return 0
}

# Reinstall the named globals that the Node now in use is missing. Never fatal:
# Node itself did move, so a package npm can't fetch is reported and left for
# the user rather than rolling the version change back.
reinstall_global_npm_packages() {
    local pkg missing=() stranded=()
    for pkg in "$@"; do
        [ -d "$FNM_GLOBALS_DIR/$pkg" ] || missing+=("$pkg")
    done
    # Nothing to carry covers the no-argument call too, so this is the only guard
    # needed — and it comes before the npm probe so the common case forks nothing.
    [ "${#missing[@]}" -gt 0 ] || return 0
    command_exists npm || return 0

    print_info "Carrying ${#missing[@]} global npm package(s) over: ${missing[*]}"
    for pkg in "${missing[@]}"; do
        npm install -g "$pkg" || stranded+=("$pkg")
    done

    if [ "${#stranded[@]}" -gt 0 ]; then
        print_warning "Left behind by the Node move: ${stranded[*]}"
        print_info "Reinstall by hand with 'npm install -g ${stranded[*]}'"
        return 0
    fi
    print_success "Global npm packages carried over"
    return 0
}

# Install the latest Node LTS, make it fnm's default and put it on PATH. Shared
# with 'dots update', which refreshes Node exactly the way the installer
# first provisions it, so the two can't drift.
#
# The carry-over lives here rather than in the updater's apply path because it
# belongs welded to the `fnm default` that causes the stranding: any future
# caller that moves Node gets the repair whether it thought about it or not.
# `dots update` is the only caller that can trigger it today — the installer
# reaches this function solely when fnm has no versions at all, where there is
# nothing to carry and the read costs one stat.
install_node_lts() {
    local carried=()
    mapfile -t carried < <(list_global_npm_packages)

    fnm install --lts && fnm default lts-latest && activate_fnm_node || return 1

    reinstall_global_npm_packages "${carried[@]}"
}

# ── Groups ───────────────────────────────────────────────────────────────────

# Group ID from its filename (packages/groups/development.yaml -> development)
get_group_id() {
    basename "$1" .yaml
}

# The chezmoi flag recording whether a group was selected (development ->
# install_development). The naming convention lives here and nowhere else.
get_chezmoi_flag() {
    echo "install_$1"
}

# True when the group defined by a yaml file is enabled in chezmoi's data.
group_enabled() {
    [ "$(chezmoi_data_get "$(get_chezmoi_flag "$(get_group_id "$1")")")" = "true" ]
}

# Fallback parser for requires_packages (used when yq is unavailable).
# Emits one package per line for the given distro family. Supports inline
# list form only (e.g. `arch: [rust, cargo]`) — which is what the yaml uses.
_parse_custom_install_requires_packages_fallback() {
    local file="$1" pkg_name="$2" family="$3"
    local in_section=false
    local found=false
    local in_req_pkgs=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^custom_install:[[:space:]]*$ ]]; then
            in_section=true
            continue
        fi
        if $in_section; then
            if [[ "$line" =~ ^[a-z] ]]; then
                break
            fi
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*${pkg_name}[[:space:]]*$ ]]; then
                found=true
                in_req_pkgs=false
                continue
            fi
            if $found && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
                break
            fi
            if $found && [[ "$line" =~ ^[[:space:]]*requires_packages:[[:space:]]*$ ]]; then
                in_req_pkgs=true
                continue
            fi
            if $found && $in_req_pkgs; then
                # Leaving the map when a line is not further indented under it.
                if [[ "$line" =~ ^[[:space:]]{0,4}[a-zA-Z_]+: ]] && ! [[ "$line" =~ ^[[:space:]]{6,} ]]; then
                    in_req_pkgs=false
                    continue
                fi
                if [[ "$line" =~ ^[[:space:]]*${family}:[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
                    local list="${BASH_REMATCH[1]}"
                    # Split on comma, trim whitespace and quotes.
                    local IFS=','
                    for item in $list; do
                        item="${item#"${item%%[![:space:]]*}"}"
                        item="${item%"${item##*[![:space:]]}"}"
                        item="${item%\"}"; item="${item#\"}"
                        item="${item%\'}"; item="${item#\'}"
                        [ -n "$item" ] && echo "$item"
                    done
                    return 0
                fi
            fi
        fi
    done < "$file"
}

# Get the packages to auto-install when a custom_install entry's `requires`
# command is missing. Resolves DISTRO_FAMILY (arch) and emits one package per
# line; empty output if nothing is declared for this family.
parse_custom_install_requires_packages() {
    local file="$1" pkg_name="$2"
    local family="${DISTRO_FAMILY:-}"
    [ -z "$family" ] && return 0

    if command_exists yq; then
        yq -r "(.custom_install // [])[] | select(.name == \"$pkg_name\") | .requires_packages.$family // [] | .[]" "$file" 2>/dev/null
    else
        _parse_custom_install_requires_packages_fallback "$file" "$pkg_name" "$family"
    fi
}

# ── Chezmoi data helpers ─────────────────────────────────────────────────────

CHEZMOI_CONF="$HOME/.config/chezmoi/chezmoi.toml"

# Read a key's value from chezmoi.toml's [data] section (quotes stripped).
chezmoi_data_get() {
    local key="$1"
    [ -f "$CHEZMOI_CONF" ] || return 0
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$CHEZMOI_CONF" 2>/dev/null | head -1 \
        | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/'
}

# Upsert a key in chezmoi.toml's [data] section. true/false are written bare,
# everything else quoted.
chezmoi_data_set() {
    local key="$1" value="$2"
    if [ ! -f "$CHEZMOI_CONF" ]; then
        print_warning "chezmoi.toml not found, skipping $key update"
        return 0
    fi
    local rendered="\"$value\""
    case "$value" in true|false) rendered="$value" ;; esac
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$CHEZMOI_CONF"; then
        sed -i "s/^[[:space:]]*${key}[[:space:]]*=.*/    ${key} = ${rendered}/" "$CHEZMOI_CONF"
    else
        sed -i "/^\[data\]/a\\    ${key} = ${rendered}" "$CHEZMOI_CONF"
    fi
}

# Whether this machine's install_purpose matches (desktop | terminal).
# $INSTALL_PURPOSE wins when it is set, and only the installer sets it. It has to:
# chezmoi.toml does not learn the purpose until setup_dotfiles writes it, which is
# after the package selector has run and after the group packages are installed — so
# on a fresh install the file answers "" for the whole phase that needs the answer,
# and a terminal install would silently keep every desktop_only package. Reading the
# in-memory value first is also what lets the installer use the shared enumerators at
# all, instead of the hand-rolled copies it grew for this reason. Unset everywhere
# else (`dots update`, `dots packages`), so those still read the file.
install_purpose_is() {
    [ "${INSTALL_PURPOSE:-$(chezmoi_data_get install_purpose)}" = "$1" ]
}

# ── Machine profile state ────────────────────────────────────────────────────
#
# Written at the end of a *successful* setup or sync and nowhere else, which is
# the whole point: a run that died halfway must not leave the machine looking
# synced. chezmoi.toml cannot play this role — setup_dotfiles writes it in the
# middle of the install, so it exists long before the install has worked.
#
# SYNCED_COMMIT is the anchor `dots update` diffs against to know what the repo
# gained since this machine last agreed with it. Without it the only question
# available is "what is missing?", which cannot tell a new package from one the
# user removed on purpose — and so re-offers the removed one forever.
PROFILE_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/profile.env"

profile_get() {
    [ -f "$PROFILE_STATE" ] || return 0
    # profile_set is the only writer and always emits KEY='value', so one
    # pattern reads it — no second pass to peel the quotes back off.
    sed -n "s/^$1='\(.*\)'$/\1/p" "$PROFILE_STATE" 2>/dev/null | head -1
}

profile_set() {
    local key="$1" value="$2"
    mkdir -p "$(dirname "$PROFILE_STATE")"
    [ -f "$PROFILE_STATE" ] || : > "$PROFILE_STATE"
    if grep -q "^${key}=" "$PROFILE_STATE"; then
        sed -i "s|^${key}=.*|${key}='${value}'|" "$PROFILE_STATE"
    else
        printf "%s='%s'\n" "$key" "$value" >> "$PROFILE_STATE"
    fi
}

# Has this machine been through the installer? Setup refuses to re-run on one
# that has, and the package tree seeds its checkboxes from reality rather than
# offering the whole catalogue again.
machine_is_managed() {
    [ -f "$PROFILE_STATE" ] && return 0
    # Machines set up before the profile file existed: chezmoi.toml is written
    # by setup_dotfiles and by nothing else, so a [data] block means the
    # installer got at least that far. Their first `dots update` writes the
    # real marker.
    [ -f "$CHEZMOI_CONF" ] && grep -q '^\[data\]' "$CHEZMOI_CONF"
}

# Stamp the machine profile. One writer for the anchor the whole design rests
# on: both `dots setup` (at the very end of a run that worked) and `dots update`
# call this, so the next key added here cannot end up written by one and not the
# other. Requires $DOTFILES_DIR.
#
# Refuses while a package shortfall is outstanding, because the anchor's meaning
# is "this machine agrees with that commit". Stamping it while a declared package
# failed to install would compute every future delta from a commit the machine
# never caught up with, and the packages left behind would never be offered again
# — the anchor would claim they had been dealt with. Silent, since the callers
# word it themselves (they know whether anything else in the run still landed);
# ask `sync_shortfall` if you need to.
record_synced_state() {
    if $SYNC_SHORTFALL; then
        return 0
    fi
    local head
    head=$(git -C "$DOTFILES_DIR" rev-parse HEAD 2>/dev/null) || head=""
    [ -n "$head" ] && profile_set SYNCED_COMMIT "$head"
    profile_set SYNCED_AT "$(date -Is)"
}

# ── Secrets & config helpers ─────────────────────────────────────────────────

SECRETS_CONF="$HOME/.config/environment.d/secrets.conf"

# Write a key=value pair to the secrets file (upsert)
set_secret() {
    local key="$1" value="$2"
    mkdir -p "$(dirname "$SECRETS_CONF")"
    if [ -f "$SECRETS_CONF" ] && grep -q "^${key}=" "$SECRETS_CONF"; then
        sed -i 's/^'"${key}"'=.*/'"${key}"'='"${value}"'/' "$SECRETS_CONF"
    else
        echo "${key}=${value}" >> "$SECRETS_CONF"
    fi
}

# ── Package list helpers ─────────────────────────────────────────────────────
#
# What a machine is *declared* to want. Every view that answers that question —
# the manage tree, `dots packages sync`, the `dots update` delta — goes through
# these two, so "declared" cannot come to mean three different things (it did:
# the update delta grew its own walk and read a packages/base.yaml that has
# never existed, silently emptying half its answer).

# Every package a group declares for this machine — distro packages then
# custom_install entries, minus the desktop-only ones on a terminal install — as
# "pkg<TAB>custom" for a custom_install entry and "pkg<TAB>" for a distro one.
#
# All three of the group's lists come from ONE yq call. They used to be three
# (`parse_packages` + `parse_custom_install_names` + `parse_desktop_only`), and
# `declared_packages_at` asked for the custom names a second time on top, so a
# 7-group tree cost 21 yq invocations and the update delta — which walks two trees
# — cost 50. That is not a rounding error: this machine has python-yq, where every
# invocation pays ~180ms of interpreter start, so the walk was ~9s of the ~10s
# scan. One call per file makes it 16.
#
# Emission order inside the query is deliberate: desktop_only and the custom names
# come first so both sets are known before the rows they classify arrive, and the
# rows are then replayed distro-first to keep the order every caller already saw.
group_declared_packages() {
    group_declared_lists "$1" | classify_declared_rows
}

# The classification half, reading tagged rows on stdin rather than a filename, so
# a caller that also wants the metadata rows can capture one read and use it twice
# instead of paying for a second yq. That is the whole reason this is split out —
# `dots packages`' catalogue needs the name, the icon, the descriptions AND the
# package rows, and it used to spend four separate invocations per group getting
# them (~5.9s of a 7.1s scan).
classify_declared_rows() {
    local terminal=false
    if install_purpose_is terminal; then
        terminal=true
    fi

    # Prefixed because common.sh is sourced by every script: a plain `custom` or
    # `distro` array here shadows the same name in whichever caller's function is
    # on the stack, and shellcheck reads it as one variable used two ways in files
    # that never mention it.
    local -A _gdp_desktop_only=() _gdp_custom_names=()
    local -a _gdp_distro=() _gdp_custom=()
    local kind name

    while IFS=$'\t' read -r kind name; do
        [ -n "$name" ] || continue
        case "$kind" in
            D) _gdp_desktop_only["$name"]=1 ;;
            # Marked by name, not by which list the row came from: a name declared
            # in both lists counted as custom before, and its install path differs.
            C) _gdp_custom_names["$name"]=1; _gdp_custom+=("$name") ;;
            P) _gdp_distro+=("$name") ;;
            # N/I/E are metadata for whoever asked for it; not our business.
        esac
    done

    for name in "${_gdp_distro[@]}" "${_gdp_custom[@]}"; do
        if $terminal && [ -n "${_gdp_desktop_only[$name]:-}" ]; then
            continue
        fi
        printf '%s\t%s\n' "$name" "${_gdp_custom_names[$name]:+custom}"
    done
}

# The one yq call: "<tag><TAB>value" rows, tagged
#   N name · I icon · E pkg=description · D desktop_only · C custom name · P package
# Metadata first, then the two sets classify_declared_rows needs before the rows
# they classify. The yq-less fallback calls the same parsers as before rather than
# reimplementing their line-oriented scanning — that path is for a machine that has
# not got yq yet, so correctness there matters and speed does not.
group_declared_lists() {
    local file="$1"
    if command_exists yq; then
        # Every value is coerced with tostring before it is concatenated. jq's `+`
        # refuses string + number and one error aborts the whole comma-expression,
        # so a single unquoted yaml scalar — `descriptions: {foo: 1.5}`, a version
        # number read as a float — emitted *no rows at all* for the file. The group
        # then looked empty everywhere at once: absent from `dots packages`, nothing
        # missing in its sync, and no packages in the update delta, with stderr
        # discarded and `|| true` swallowing the status. The four separate parsers
        # this replaced could only ever lose the one list they parsed.
        yq -r "
          (\"N\t\" + ((.name // \"\") | tostring)),
          (\"I\t\" + ((.icon // \"\") | tostring)),
          ((.descriptions // {}) | to_entries[] | \"E\t\" + (.key | tostring) + \"=\" + ((.value // \"\") | tostring)),
          ((.desktop_only // [])[]?   | select(. != null) | \"D\t\" + tostring),
          ((.custom_install // [])[]? | .name | select(. != null) | \"C\t\" + tostring),
          ((.packages.${DISTRO_FAMILY} // [])[]? | select(. != null) | \"P\t\" + tostring)
        " "$file" 2>/dev/null | grep -v "^.	#" || true
    else
        printf 'N\t%s\n' "$(grep -m1 '^name:' "$file" | sed 's/^name:[[:space:]]*//')"
        printf 'I\t%s\n' "$(grep -m1 '^icon:' "$file" | sed 's/^icon:[[:space:]]*//')"
        parse_descriptions "$file" | sed 's/^/E\t/'
        parse_desktop_only "$file" | sed 's/^/D\t/'
        parse_custom_install_names "$file" | sed 's/^/C\t/'
        parse_packages "$file" "$DISTRO_FAMILY" | sed 's/^/P\t/'
    fi
}

# One read of a group file, exposing everything a view needs from it: GROUP_NAME,
# GROUP_ICON and DESCRIPTIONS are set for the caller, and GROUP_ROWS keeps the raw
# tagged text so the package rows can be classified without reading the file again
# (pipe it into classify_declared_rows). Globals rather than stdout because a
# command substitution or a pipe would put the assignments in a subshell — the same
# constraint choose_or_abort works around.
#
# Replaces the name + icon + descriptions + package-list sequence every view used
# to open with (its four helpers are gone): four yq invocations per group where one
# does.
# shellcheck disable=SC2034  # GROUP_ICON/GROUP_ROWS are read by callers
load_group_meta() {
    local file="$1"
    GROUP_NAME=""
    GROUP_ICON=""
    declare -gA DESCRIPTIONS=()
    GROUP_ROWS=$(group_declared_lists "$file")

    local tag value
    while IFS=$'\t' read -r tag value; do
        case "$tag" in
            N) GROUP_NAME="$value" ;;
            I) GROUP_ICON="$value" ;;
            E) [ -n "$value" ] && DESCRIPTIONS["${value%%=*}"]="${value#*=}" ;;
        esac
    done <<< "$GROUP_ROWS"
}

# Names only, in the same order — the shape every caller but the update delta
# wants. The delta needs the custom flag too, and takes group_declared_packages
# directly rather than re-deriving it with another parse.
get_group_packages() {
    group_declared_packages "$1" | cut -f1
}

# One list base.yaml declares under `<key>:`, unioned across the sections this
# machine wants — the always-on ones, plus the desktop ones unless this is a
# terminal-only install. Takes the packages/ directory to read, so the same walk
# serves the current checkout and a worktree exported at an older commit.
#
# Parameterised rather than written once per key: the purpose gating is the rule
# most likely to change (a third purpose, another `*_aur`-style variant) and two
# copies of it would diverge on the first such change. One yq call rather than
# one per section, for the reason in group_declared_packages.
_base_desired_list() {
    local key="$1" dir="$2" always="$3" desktop_only="$4"
    local base_file="${dir:-${PACKAGES_DIR:-}}/$DISTRO_FAMILY/base.yaml"
    [ -f "$base_file" ] || return 0

    local sections=()
    read -ra sections <<< "$always"
    if ! install_purpose_is terminal; then
        local extra=()
        read -ra extra <<< "$desktop_only"
        sections+=("${extra[@]}")
    fi

    local section
    if command_exists yq; then
        # `select(. != null)` for the reason group_declared_lists carries one: `[]?`
        # tolerates a missing key but not a null *entry*, and with -r a null list
        # item prints as the literal string `null`, which then reaches pacman as a
        # package name. Parenthesised because `|` binds looser than `,`.
        local query=""
        for section in "${sections[@]}"; do
            query+="((.${key}.${section} // [])[]? | select(. != null)),"
        done
        yq -r "${query%,}" "$base_file" 2>/dev/null | grep -v '^[[:space:]]*$' || true
    else
        for section in "${sections[@]}"; do
            parse_yaml_nested_list "$base_file" "$key" "$section"
        done
    fi
}

base_desired_packages() { _base_desired_list packages "${1:-}" "core aur" "desktop desktop_aur"; }

# base.yaml gained a `services:` key so bluetooth could stop being a group's
# business. It was declared by both hyprland and gaming — hyprland because a
# desktop wants it, gaming because `xpadneo-dkms` pairs an Xbox controller over
# it — which is two groups each asserting a baseline rather than a need of their
# own, and left a machine's bluetooth depending on which checkboxes happened to
# be ticked. `blueman` stays in hyprland: the tray applet belongs to the shell
# that has a tray, unlike the stack underneath it.
base_desired_services() { _base_desired_list services "${1:-}" "core" "desktop"; }

# ── Package install helpers ──────────────────────────────────────────────────

# Build an in-memory set of every installed package (one query, not one per
# package). Populates the global INSTALLED_SET associative array.
#
# Shared by `dots packages` (which pre-checks what you have) and by the
# installer's selection tree (which seeds its checkboxes the same way on a
# machine that is already set up), so "already installed" cannot come to mean
# two different things in the two views.
# shellcheck disable=SC2034  # read by the callers this is declared -g for
build_installed_index() {
    declare -gA INSTALLED_SET=()
    local pkg
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && INSTALLED_SET["$pkg"]=1
    done < <(list_installed_packages)
}

# build_installed_index unless a caller already built it this run. The query is
# ~0.3s over a few thousand packages, and a single command can want the index
# from two phases that neither install nor remove anything between them.
# Anything that *does* change what is installed must call build_installed_index.
ensure_installed_index() {
    [ "${#INSTALLED_SET[@]}" -gt 0 ] || build_installed_index
}

# Install one `custom_install:` entry using the command its yaml declares.
# A declared `requires:` that is absent is a skip, not a failure: the entry
# needs a toolchain this machine has not got, and saying so beats a build error.
# Install the system packages a custom_install entry declares under
# `requires_packages:`, skipping any already present. Returns non-zero only when
# the install itself failed, so each caller words its own report.
#
# The single implementation of a step that was written twice: installer.sh had it
# inline, which meant requires_packages had exactly one consumer and every path
# reaching an entry through install_custom_pkg — `dots update`,
# `dots packages sync`, the manage view — silently skipped it. Harmless while
# every such entry also had an `install:` that pulled its own dependencies, and
# not harmless at all for an entry whose declared prerequisite is the whole
# point: the two chat shells have no install command (chezmoi owns their files),
# so on those paths they were a no-op that reported success and left
# python-pyqt6-webengine uninstalled — two launchers dying with an ImportError.
#
# Called before the `requires` command gate, because a requires_packages list is
# often what *provides* the required command.
install_custom_requires() {
    local file="$1" pkg="$2"

    # grep before yq: of the custom entries across packages/, only a handful
    # declare this key, and yq is ~180ms of interpreter start. Reading an absent
    # key was the single most expensive thing on the catch-up path, paid once per
    # entry installed.
    grep -q 'requires_packages:' "$file" 2>/dev/null || return 0

    local -a require_deps=()
    local dep
    while IFS= read -r dep; do
        [ -n "$dep" ] && require_deps+=("$dep")
    done < <(parse_custom_install_requires_packages "$file" "$pkg")
    [ ${#require_deps[@]} -gt 0 ] || return 0

    # The batch index rather than a `pacman -Qi` per dependency: one -Qi costs
    # more than indexing the whole database, and two entries here declare the
    # same runtime. ensure_installed_index rather than a raw read because
    # install_packages invalidates the index on its way out.
    ensure_installed_index
    local -a missing=()
    for dep in "${require_deps[@]}"; do
        [ -n "${INSTALLED_SET[${dep#*/}]:-}" ] || missing+=("$dep")
    done
    [ ${#missing[@]} -gt 0 ] || return 0

    print_info "Installing prerequisites for $pkg (${missing[*]})"
    install_packages "${missing[@]}" || return 1
    hash -r 2>/dev/null || true
    return 0
}

install_custom_pkg() {
    local file="$1" pkg="$2"
    local install_cmd requires_cmd
    install_cmd=$(parse_custom_install_cmd "$file" "$pkg")
    requires_cmd=$(parse_custom_install_requires "$file" "$pkg")
    # No shortfall on this path, unlike the install failure below: a missing
    # toolchain is a standing property of the machine, not something this run fell
    # short of, and the flag is never cleared. Marking it froze the anchor for good
    # — the same skip recurred every run, so the delta was recomputed from the same
    # ancient commit forever and re-prompted for packages the machine had decided
    # not to build. The warning is the report; `dots packages sync` lists it on
    # demand.
    install_custom_requires "$file" "$pkg" || {
        print_warning "Failed to install prerequisites for $pkg"
        mark_sync_shortfall
    }

    if [ -n "$requires_cmd" ] && ! command_exists "$requires_cmd"; then
        print_warning "$requires_cmd not found — skipping $pkg"
        return 0
    fi
    if [ -n "$install_cmd" ]; then
        install_curl_tool "$pkg" "$install_cmd" || {
            print_warning "Failed to install $pkg"
            mark_sync_shortfall
        }
    fi
}

# Install a tool via curl script
install_curl_tool() {
    local name="$1"
    local install_cmd="$2"
    
    print_info "Installing $name..."
    if eval "$install_cmd"; then
        print_success "$name installed successfully"
        return 0
    else
        print_error "Failed to install $name"
        return 1
    fi
}

# Clone a git repository
install_git_repo() {
    local name="$1"
    local url="$2"
    local dest="$3"
    
    # Expand ~ to $HOME
    dest="${dest/#\~/$HOME}"
    
    if [ -d "$dest" ]; then
        print_info "$name already exists at $dest"
        return 0
    fi
    
    print_info "Cloning $name to $dest..."
    mkdir -p "$(dirname "$dest")"
    if git clone "$url" "$dest"; then
        print_success "$name cloned successfully"
        return 0
    else
        print_error "Failed to clone $name"
        return 1
    fi
}
