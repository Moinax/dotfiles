#!/bin/bash
# Arch Linux specific package management functions

# Source common functions (use local var to avoid overwriting parent's SCRIPT_DIR)
_DISTRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DISTRO_DIR/../lib/common.sh"

# Why the last _run_pkg_cmd failed, for callers that can act on it. Only the
# stale-database case is worth distinguishing: it is the one failure that is not
# transient and that a plain retry can never fix.
_PKG_CMD_STALE_DB=false

# Whether the packages being installed are ones a yaml declares. True by default,
# because nearly every install is; the exceptions declare `local _PKG_DECLARED=false`
# (or go through install_optional_packages) and are the bootstrap tools and optional
# extras. Only a declared package withholds the sync anchor: the anchor's meaning is
# "this machine agrees with that commit", and a failed extra is one `dots packages
# sync` can neither list nor repair — marking it left an unclearable shortfall whose
# own advice reported nothing to fix.
_PKG_DECLARED=true

# Run a pacman/paru command, converting "up to date" messages to info and
# suppressing boilerplate noise. Output is filtered in real time via a pipe
# so that download/install progress remains visible. A failure of unknown cause
# prints an unmissable banner with the exact command — a transient mirror/download
# error once aborted the whole base-package transaction and the generic
# "some packages failed" warning made it easy to overlook. A failure whose cause
# this recognises reports the cause instead; see the branch at the bottom.
_run_pkg_cmd() {
    local rc=0 stale_db
    _PKG_CMD_STALE_DB=false
    # Written from inside the pipe, so it has to be a file: the while loop runs in
    # a subshell and a variable set there does not survive it.
    #
    # A fixed name per process rather than mktemp's random one, removed on the way in
    # as well as out: the cleanup below is skipped whenever the interrupt trap exits
    # mid-command, and a random name leaked one file per interrupted install.
    stale_db="${TMPDIR:-/tmp}/dots-staledb.$$"
    rm -f "$stale_db"
    # LC_ALL=C because every branch below matches pacman's *English* output, the 404
    # line included. Without it a translated locale silently disabled the whole
    # stale-database recovery: the cause went unrecognised and the user was told to
    # re-run a command that 404s identically every time. The two pacman readers
    # further down this file already pin it for the same reason. Prefix assignment
    # rather than `sudo LC_ALL=C`: sudo's compiled defaults pass LC_* through, and
    # the sudoers here may not permit an explicit assignment.
    LC_ALL=C "$@" 2>&1 | while IFS= read -r line; do
        if [[ "$line" =~ ^warning:\ (.+)\ is\ up\ to\ date\ --\ skipping$ ]]; then
            print_info "Already installed: ${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^::\ (.+)\ is\ up\ to\ date\ --\ skipping$ ]]; then
            print_info "Already installed: ${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^\ *there\ is\ nothing\ to\ do\ *$ ]]; then
            :
        elif [[ "$line" =~ ^::\ (Resolving\ dependencies|Calculating\ (inner\ )?conflicts)\.\.\. ]]; then
            :
        else
            # A 404 on the package file is not a network problem and re-running
            # changes nothing: the local sync database names a version the mirrors
            # have already replaced, so it asks every one of them for a filename
            # that no longer exists. Worth calling out, because the symptom is
            # fifty lines of per-mirror errors that read like a flaky connection.
            [[ "$line" == *"failed retrieving file"*404* ]] && echo 1 >"$stale_db"
            echo "$line"
        fi
    done
    rc="${PIPESTATUS[0]}"
    [ -s "$stale_db" ] && _PKG_CMD_STALE_DB=true
    rm -f "$stale_db"
    if [ "$rc" -ne 0 ]; then
        # A known cause gets one line and no banner. The banner exists so a
        # transient failure is not overlooked and can be retried by hand — but here
        # the cause is named, the command is about to be retried for you, and
        # echoing it back as something to re-run would be wrong advice on top of
        # noise. The pacman output above already ends with its own two errors.
        if $_PKG_CMD_STALE_DB; then
            print_warning "The mirrors 404'd: this package database is older than they are, so only an upgrade can fix it."
        else
            print_error "Package command failed (exit $rc): $*"
            print_error "Scroll up for pacman's error output; re-run the command above to retry."
        fi
    fi
    return "$rc"
}

# Drop packages pinned via pacman's IgnorePkg. An explicit `pacman -S --noconfirm`
# would otherwise auto-answer the "install anyway?" prompt and override the pin.
# Echoes the surviving packages, one per line.
_strip_ignored_pkgs() {
    local ignored
    ignored="$(pacman-conf IgnorePkg 2>/dev/null)" || { printf '%s\n' "$@"; return; }
    local pkg
    for pkg in "$@"; do
        if grep -qxF -- "$pkg" <<<"$ignored"; then
            print_warning "Skipping pinned package (IgnorePkg): $pkg" >&2
        else
            printf '%s\n' "$pkg"
        fi
    done
}

# Check if paru is installed, install if not
ensure_paru() {
    if command_exists paru; then
        print_info "paru is already installed"
        return 0
    fi
    
    print_info "Installing paru (AUR helper)..."
    
    # Ensure base-devel and git are installed. Not a declared package: paru is
    # bootstrap, and a failure here is reported by the caller, not by the anchor.
    local _PKG_DECLARED=false
    _install_with_db_recovery sudo pacman -S --needed --noconfirm git base-devel
    
    # Clone and build paru
    local temp_dir="/tmp/paru-build"
    rm -rf "$temp_dir"
    git clone https://aur.archlinux.org/paru.git "$temp_dir"
    
    (
        cd "$temp_dir" || exit 1
        makepkg -si --noconfirm
    )
    
    rm -rf "$temp_dir"
    
    if command_exists paru; then
        print_success "paru installed successfully"
        return 0
    else
        print_error "Failed to install paru"
        return 1
    fi
}

# Update the system. With "confirm", the package list is shown and confirmed
# before applying; otherwise it runs non-interactively (used by the installer).
# Prefer paru so AUR packages are updated alongside repo ones (consistent with
# install_packages); paru escalates privileges itself, so it takes no sudo. Fall
# back to pacman (repo only) if paru isn't installed.
update_system() {
    local mgr=(sudo pacman) scope=""
    if command_exists paru; then
        mgr=(paru)
        scope=" (repo + AUR)"
    fi

    if [ "${1:-}" = "confirm" ]; then
        print_info "Checking for system updates${scope}..."
        "${mgr[@]}" -Syu
    else
        print_info "Updating system${scope}..."
        "${mgr[@]}" -Syu --noconfirm
    fi
}

# ── Stale-database recovery ──────────────────────────────────────────────────
# Installing a package needs a database no older than the mirrors, and only
# `dots setup` ever guaranteed that (it opens with update_system). The day-to-day
# paths — `dots update`, `dots packages` — install against whatever database the
# machine happens to have, which after a few days names versions the mirrors have
# already rebuilt: every mirror then 404s on a filename that no longer exists.
#
# So the upgrade is offered exactly where the failure proves it is needed, rather
# than run up front on every install. That keeps the standing rule intact — pacman
# and AUR upgrades belong to cachy-update, and `dots` does not quietly become a
# system upgrader — while still making the one case that demands one recoverable
# without leaving the command.

# Returns 0 once the database is fresh and the caller should retry. It has no
# other return: every way of not fixing it ends the run instead.
#
# That is deliberate and it is the whole point. A stale database is not a package
# that failed to build or a tool this machine lacks a toolchain for — it means the
# repo's packages *cannot* be installed here at all, so carrying on would apply the
# configs, the tool refresh and the surface reloads around a hole. That state is
# the one worth avoiding above all: a machine that looks synced, reports success,
# and is missing what the configs it just applied were written for. There is
# nothing to weigh, so declining, cancelling and having nobody to ask are all the
# same answer — stop, and say what to run.
_recover_stale_db() {
    # Non-interactive (an installer under a pipe, a cron sync): nobody to ask.
    if ! command_exists gum || [ ! -t 0 ]; then
        print_error "Cannot install against a stale database."
        print_info "Run 'cachy-update' to refresh it, then run this again."
        exit 1
    fi

    # No explanation printed above the prompt: _run_pkg_cmd's one line already
    # said the database is behind and that an upgrade is the only fix, which is
    # everything needed to answer this. (The reason it cannot be a database
    # refresh alone: the version the install wants is the one the mirrors have,
    # and that version belongs to the pending upgrade — refreshing the database
    # without taking it just moves the failure to a missing dependency.)
    echo ""
    # Yes is the only answer that continues, so all three ways of saying no —
    # the button, Esc, Ctrl+C — land in the same place. confirm_or_abort still
    # earns its keep: it keeps a cancel reporting as an interrupt (130) rather
    # than as a decision, which is what the caller's exit status should say.
    if ! confirm_or_abort "Upgrade the system (repo + AUR) and retry the install?"; then
        print_warning "Stopped — nothing else was applied."
        print_info "Run 'cachy-update' when you are ready, then run this again."
        exit 1
    fi

    # `confirm` rather than the non-interactive form on purpose: this upgrade is
    # far larger than the install that triggered it, so paru shows the transaction
    # and its download size before anything is committed.
    if ! update_system confirm; then
        print_error "System upgrade failed — the database is still stale, so nothing else was applied."
        exit 1
    fi

    # An upgrade is exactly the "something changed what is installed" that
    # build_installed_index's contract says invalidates the cached index. Dropped
    # rather than rebuilt: on the `dots update` path nothing reads it after this
    # (the scan's copy lived in spin_capture's subshell), so rebuilding here would
    # spend a full pacman query on an answer no one asks for. ensure_installed_index
    # rebuilds on demand for the callers that do read it.
    unset INSTALLED_SET
    return 0
}

# Run an install, and if it failed only because the database was stale, offer the
# upgrade that fixes it and run it again. One wrapper for all three install
# entry points, so the recovery cannot end up on some of them and not others.
_install_with_db_recovery() {
    # Guarded with `if` rather than `&&`: a bare failing && list is what `set -e`
    # exits the whole script on.
    if _run_pkg_cmd "$@"; then
        return 0
    fi
    if $_PKG_CMD_STALE_DB; then
        # No `|| return 1`: _recover_stale_db either refreshed the database or
        # already ended the run. That is also why it cannot be asked twice in one
        # run, so there is no "already offered" state to carry between batches.
        _recover_stale_db
        print_info "Database refreshed — retrying the install."
        if _run_pkg_cmd "$@"; then
            return 0
        fi
    fi
    # Marked here rather than at each call site: every install in this file goes
    # through this function, so "a declared package did not land" is recorded once
    # instead of relying on nine callers to remember it. Callers still get the
    # non-zero status and still decide whether to carry on.
    #
    # Marked only once the retry has also failed. Marking on the first failure read
    # a recovery that then installed everything as a shortfall, and since nothing
    # clears the flag, a fully successful stale-database recovery still refused the
    # anchor and reported packages left behind that were not.
    if $_PKG_DECLARED; then
        mark_sync_shortfall
    fi
    return 1
}

# Install packages that no yaml declares — an optional extra, or a tool a later step
# needs. Same database recovery; see _PKG_DECLARED for why the anchor is not withheld.
# `local` reaches _install_with_db_recovery through bash's dynamic scoping, so the
# whole call tree below this one is covered by the single assignment.
install_optional_packages() {
    local _PKG_DECLARED=false
    install_packages "$@"
}

# Install all packages (handles both official and AUR)
install_packages() {
    local packages=("$@")
    
    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    mapfile -t packages < <(_strip_ignored_pkgs "${packages[@]}")
    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    ensure_paru

    print_info "Installing ${#packages[@]} packages..."
    _install_with_db_recovery paru -S --needed --noconfirm "${packages[@]}"
}

# Remove packages
remove_packages() {
    local packages=("$@")

    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    print_info "Removing packages: ${packages[*]}"
    sudo pacman -Rns --noconfirm "${packages[@]}"
}

# Check if a package is installed
is_package_installed() {
    local package="$1"
    pacman -Qi "$package" &>/dev/null
}

# Which installed package owns each given file path. Emits
# "path<TAB>package<TAB>version" for the owned paths and nothing for the rest
# (pacman reports those on stderr and carries on, so one call covers a mixed
# batch). Batched deliberately: -Qo is a full database query and callers ask
# about every binary in a scan at once.
package_owners() {
    [ $# -gt 0 ] || return 0
    LC_ALL=C pacman -Qo "$@" 2>/dev/null | awk '
        {
            i = index($0, " is owned by ")
            if (i == 0) next
            path = substr($0, 1, i - 1)
            if (split(substr($0, i + 13), a, " ") < 2) next
            printf "%s\t%s\t%s\n", path, a[1], a[2]
        }' || true
}

# List every installed package name, one per line. Used to build an in-memory
# index so callers can test many packages without forking pacman per package.
#
# Beyond the real package names (pacman -Qq), this also emits everything those
# packages Provide/Replace, so virtual or renamed packages resolve the same way
# a per-package `pacman -Qi <name>` would (e.g. `vi` provides `vim`).
list_installed_packages() {
    installed_package_aliases | cut -f1
}

# The same three fields, kept as a mapping instead of flattened: one
# "name<TAB>installed package" row per name a package answers to, its own
# included.
#
# The flat set above can only answer "is this here?", which is all an install
# check needs. A *removal* has to act on the answer, and there the name the
# dotfiles declare is not necessarily the name pacman holds: the yaml said
# `rofi-wayland` and this machine had `rofi`, which replaced it, so
# `pacman -R rofi-wayland` is a "target not found" and the drop would have been
# skipped in silence — on the very package that motivated the feature. Keeping
# the mapping is what lets a caller turn a declared name into a removable one.
#
# The two are one parser on purpose. This used to be two, and the fallback half
# never emitted a package's own name (`pacman -Qq` was a separate call bolted in
# front of it), which is exactly the sort of drift that makes a rarely-taken
# branch wrong.
#
# **One row per name, conflicts already resolved.** The raw emitters below are a
# multimap — an alias can legitimately come from two packages, and a package's
# own name can collide with another's `provides`: `dbus-broker-units` provides
# `dbus-units`, which is itself installed here. Resolving that ("a package's own
# name always wins") is a property of what this mapping *means*, so it happens
# once, here, rather than in whatever fold each caller writes. Left to the
# caller it was a three-line rule that a second caller would silently omit — and
# omitting it means handing `pacman -Rs` the wrong package.
#
# expac asks libalpm for exactly these three fields and prints them; `pacman -Qi`
# formats every field of every package and has them parsed back out, which costs
# 830ms against expac's 48ms on ~2600 packages. Worth the branch because every
# `dots packages` and `dots update` scan pays this, and the fallback still has to
# exist for a machine whose expac is not installed yet (base.yaml declares it, so
# that is a first run — or a removal this very feature offered).
installed_package_aliases() {
    _emit_package_aliases | awk -F'\t' '
        # Own-name rows overwrite; among genuine aliases the first one wins.
        { if ($1 == $2 || !($1 in real)) real[$1] = $2 }
        END { for (a in real) print a "\t" real[a] }'
}

# The raw multimap the resolver above consumes: one "name<TAB>package" row per
# name a package answers to, its own included, in database order.
_emit_package_aliases() {
    if command_exists expac; then
        # %n %S %R = name, provides, replaces, pipe-separated so the three
        # fields survive a split that the space-separated list items also need.
        expac -Q '%n|%S|%R' 2>/dev/null | awk -F'|' '
            {
                name = $1
                gsub(/^[ \t]+|[ \t]+$/, "", name)
                if (name == "") next
                print name "\t" name
                for (f = 2; f <= 3; f++) {
                    c = split($f, a, /[[:space:]]+/)
                    for (i = 1; i <= c; i++) {
                        p = a[i]
                        sub(/[<>=].*$/, "", p)   # strip version constraints (foo=1.2)
                        # `None` is the sentinel pacman -Qi prints for an empty
                        # list; expac prints nothing at all. Filtered on both
                        # paths so the two are readable as the same rule.
                        if (p != "" && p != "None") print p "\t" name
                    }
                }
            }' || true
        return
    fi

    LC_ALL=C pacman -Qi 2>/dev/null | awk -F': ' '
        /^Name[[:space:]]*:/ {
            name = $2
            gsub(/^[ \t]+|[ \t]+$/, "", name)
            if (name != "") print name "\t" name
            next
        }
        /^(Provides|Replaces)[[:space:]]*:/ {
            if (name == "") next
            c = split($2, a, /[[:space:]]+/)
            for (i = 1; i <= c; i++) {
                p = a[i]
                sub(/[<>=].*$/, "", p)
                if (p != "" && p != "None") print p "\t" name
            }
        }'
}

# Names this machine holds because something asked for them, as opposed to the
# ones pacman pulled in to satisfy a dependency. The distinction is what makes an
# automated removal safe to *offer*: `expac` itself reads as a dependency here,
# because cachyos-fish-config requires it, so dropping it from a yaml would be no
# reason at all to take it off the machine.
list_explicit_packages() {
    if command_exists expac; then
        expac -Q '%n\t%w' 2>/dev/null | awk -F'\t' '$2 == "explicit" { print $1 }' || true
        return
    fi
    pacman -Qeq 2>/dev/null || true
}

# What removing these packages would actually do: the named ones plus every
# dependency left with nothing needing it, which is what -Rs cascades to and what
# the user has to see before agreeing. --print makes the whole thing a query, so
# it needs no root and changes nothing.
#
# Non-zero when pacman refuses to prepare the transaction at all. That is the
# point as much as the listing is — it is how a package something else still
# requires gets detected, and pacman's own resolver is a far better judge of that
# than any test this repo could write.
plan_removal() {
    [ $# -gt 0 ] || return 0
    LC_ALL=C pacman -Rs --print --print-format '%n' "$@" 2>/dev/null
}

# The bootstrap tools — installed before the package phase, so they are not
# "declared packages" and must not count towards the sync anchor. yq goes
# through pacman: it is in the official repos and this runs before paru exists
# on a fresh machine.
install_bootstrap_pkg() {
    local pkg="$1"
    if command_exists "$pkg"; then
        print_info "$pkg is already installed"
        return 0
    fi

    print_info "Installing $pkg..."
    local _PKG_DECLARED=false
    if [ "$pkg" = "yq" ]; then
        _install_with_db_recovery sudo pacman -S --needed --noconfirm yq
    else
        ensure_paru
        _install_with_db_recovery paru -S --needed --noconfirm "$pkg"
    fi
}

install_gum()     { install_bootstrap_pkg gum; }
install_chezmoi() { install_bootstrap_pkg chezmoi; }
install_yq()      { install_bootstrap_pkg yq; }

# Install AppImage runtime support
install_appimage_support() {
    if is_package_installed fuse2; then
        print_info "AppImage runtime support is already installed via fuse2"
        return 0
    fi

    print_info "Installing AppImage runtime support via fuse2..."
    install_optional_packages fuse2
}
