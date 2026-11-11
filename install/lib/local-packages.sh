#!/bin/bash
# Repo packages carried with a patch of ours that upstream does not ship yet.
#
# packages/local/<pkg>/ holds only *.patch files. The PKGBUILD is never copied
# here: it is fetched from Arch's packaging repo at the version the sync repo
# currently offers, so a version bump needs nothing from us unless the patch
# itself stops applying.
#
# Two halves keep the fix on the machine:
# - IgnorePkg keeps pacman (and cachy-update, paru) from replacing the patched
#   build, and makes it print "ignoring package upgrade (a => b)" on every
#   upgrade -- the reminder comes for free from pacman itself.
# - reconcile_local_packages (dots update) rebuilds once the repo moves past the
#   installed version, or when the installed build is not ours at all. The
#   patch is tried against the new sources first, which settles three cases:
#     applies          -> upstream still lacks the fix: build and install
#     applies reversed -> upstream ships it: unpin and go back to the repo build
#     neither          -> it needs a rebase: keep the old patched build pinned
#   The last two verdicts are remembered per repo version and patch, so a run
#   that would reach the same one again only repeats the message.
#
# makepkg -s installs makedepends --asdeps, and once the build is done they are
# orphans that cachy-update offers to remove on every run. So the ones this
# build added are removed with it; a rebuild only happens when the repo moves,
# and reinstalling them then is cheap.
#
# Requires common.sh (print helpers, track_warning) to be sourced.

LOCAL_PACKAGES_DIR="$DOTFILES_DIR/packages/local"
# Appended to pkgdesc, so `pacman -Qi` shows the build is ours and this file can
# tell it apart from the repo's build at the same version.
LOCAL_PACKAGES_MARKER="[dotfiles patch]"
LOCAL_PACKAGES_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/local-packages"

_local_pkg_ignored() {
    pacman-conf IgnorePkg 2>/dev/null | grep -qxF "$1"
}

# $1: the sorted `pacman -Qdtq` taken before makepkg -s ran. A makedepend the
# dotfiles also declare (cmake, in development) stays: makepkg installed it
# first, so it reads as a dependency, and removing it would undo the group.
#
# -Rn, level by level, rather than -Rns: the recursive form also takes a
# makedepend's own dependencies, which the declared filter never sees.
_local_pkg_drop_makedeps() {
    local declared="" ; local -a added
    while :; do
        mapfile -t added < <(comm -13 "$1" <(pacman -Qdtq 2>/dev/null | sort))
        [ ${#added[@]} -gt 0 ] || return 0
        [ -n "$declared" ] || declared="$(declared_packages_at "$DOTFILES_DIR" | cut -f1)"
        mapfile -t added < <(printf '%s\n' "${added[@]}" | grep -vxFf <(printf '%s\n' "$declared"))
        [ ${#added[@]} -gt 0 ] || return 0
        print_info "Removing the build dependencies this build installed: ${added[*]}"
        sudo pacman -Rn --noconfirm "${added[@]}" || {
            track_warning "could not remove build dependencies: ${added[*]}"; return 0; }
    done
}

_local_pkg_pin() {
    _local_pkg_ignored "$1" && return 0
    print_info "Pinning $1 with IgnorePkg so upgrades keep the patched build"
    sudo sed -i "/^\[options\]/a IgnorePkg = $1" /etc/pacman.conf
}

_local_pkg_unpin() {
    _local_pkg_ignored "$1" || return 0
    sudo sed -i "/^IgnorePkg = $1\$/d" /etc/pacman.conf
}

# The source dir (a PKGBUILD may unpack several -- xdph unpacks two) that $patch
# applies to with the given patch(1) flags; nothing when none takes it.
# --fuzz=0 everywhere: with patch's default fuzz, a patch already applied, or one
# whose context moved, can still "apply" and turn upstream/stale into a rebuild.
_local_pkg_patch_dir() {
    local srcdir="$1" patch="$2" dir
    shift 2
    for dir in "$srcdir"/*/; do
        if patch -p1 -s -f --fuzz=0 --dry-run "$@" -d "$dir" <"$patch" >/dev/null 2>&1; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

# apply / upstream / stale for the whole set of patches.
_local_pkg_patch_state() {
    local srcdir="$1" pkgdir="$2" patch state=apply
    for patch in "$pkgdir"/*.patch; do
        if _local_pkg_patch_dir "$srcdir" "$patch" -N >/dev/null; then
            continue
        elif _local_pkg_patch_dir "$srcdir" "$patch" -R >/dev/null; then
            # ponytail: one upstreamed patch unpins the package even if another
            # still applies; split it when a package carries more than one fix.
            state=upstream
        else
            echo stale
            return 0
        fi
    done
    echo "$state"
}

_local_pkg_apply_patches() {
    local srcdir="$1" pkgdir="$2" patch dir
    for patch in "$pkgdir"/*.patch; do
        dir="$(_local_pkg_patch_dir "$srcdir" "$patch" -N)" || return 1
        patch -p1 -N -s -f --fuzz=0 -d "$dir" <"$patch" || return 1
    done
}

# What a remembered verdict means, said again on every run it still holds.
_local_pkg_report() {
    local pkg="$1" ver="$2" verdict="$3" installed="$4"
    case "$verdict" in
        upstream) print_info "$pkg $ver ships our fix upstream — delete packages/local/$pkg/ from the dotfiles" ;;
        stale) track_warning "$pkg: our patch no longer applies to $ver — keeping $installed pinned; rebase packages/local/$pkg/*.patch" ;;
    esac
}

_local_pkg_sync() {
    local pkg="$1" pkgdir="$LOCAL_PACKAGES_DIR/$1"
    local installed repo
    installed="$(pacman -Q "$pkg" 2>/dev/null)" || return 0  # not on this machine
    installed="${installed#* }"
    repo="$(LC_ALL=C pacman -Si "$pkg" 2>/dev/null | awk '/^Version/{print $3; exit}')" || return 0
    [ -n "$repo" ] || return 0

    # Up to date: our build, and the repo has not moved past its pkgver. pkgrel
    # is ignored -- CachyOS rebuilds (1.5.0-1.1) are not new upstream code.
    if LC_ALL=C pacman -Qi "$pkg" | grep '^Description' | grep -qF "$LOCAL_PACKAGES_MARKER" &&
        [ "$(vercmp "${repo%-*}" "${installed%-*}")" -le 0 ]; then
        _local_pkg_pin "$pkg"
        return 0
    fi

    # ponytail: assumes no epoch; Arch tags an epoch'd version as <epoch>-<ver>-<rel>.
    local ver="${repo%-*}" state key
    state="$LOCAL_PACKAGES_STATE/$pkg"
    key="$repo $(cat "$pkgdir"/*.patch | sha256sum | cut -d' ' -f1)"
    if [ -f "$state" ] && [ "$(head -1 "$state")" = "$key" ]; then
        _local_pkg_report "$pkg" "$ver" "$(sed -n 2p "$state")" "$installed"
        return 0
    fi

    print_header "Patched Package: $pkg"
    print_info "Installed $installed, repo offers $repo — checking whether it still needs our patch"

    local url="https://gitlab.archlinux.org/archlinux/packaging/packages/$pkg.git" tag work verdict
    tag="$(git ls-remote --tags --refs "$url" "$ver-*" 2>/dev/null | sed 's|.*refs/tags/||' | sort -V | tail -1)" || true
    if [ -z "$tag" ]; then
        track_warning "$pkg: no Arch packaging tag for $ver reachable — keeping $installed, retry on the next update"
        return 0
    fi

    work="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$work'; trap - RETURN" RETURN
    git clone -q --depth 1 --branch "$tag" "$url" "$work" || {
        track_warning "$pkg: could not fetch the Arch PKGBUILD ($tag)"; return 0; }
    # After the clone, which refuses a non-empty target, and before makepkg -s
    # installs anything.
    { pacman -Qdtq 2>/dev/null || true; } | sort >"$work/.orphans"
    # shellcheck disable=SC2064
    trap "_local_pkg_drop_makedeps '$work/.orphans'; rm -rf '$work'; trap - RETURN" RETURN
    echo "pkgdesc+=\" $LOCAL_PACKAGES_MARKER\"" >>"$work/PKGBUILD"
    # Pinned so a BUILDDIR/PKGDEST in makepkg.conf cannot move the tree we patch
    # or the package we install.
    local -x BUILDDIR="$work/build" PKGDEST="$work/out"
    local src="$work/build/$pkg/src"

    # -o: download, extract and run prepare(), so the patch lands on the tree
    # the build will actually see.
    (cd "$work" && makepkg -so --noconfirm) || {
        track_warning "$pkg: preparing the $tag sources failed"; return 0; }

    verdict="$(_local_pkg_patch_state "$src" "$pkgdir")"
    case "$verdict" in
        upstream)
            _local_pkg_unpin "$pkg"
            sudo pacman -S --noconfirm "$pkg" || {
                track_warning "$pkg: reinstalling the repo build failed"; return 0; }
            ;;
        stale)
            _local_pkg_pin "$pkg"
            ;;
        apply)
            _local_pkg_apply_patches "$src" "$pkgdir" &&
                (cd "$work" && makepkg -e --noconfirm) || {
                track_warning "$pkg: building the patched $ver failed — keeping $installed"; return 0; }
            # Pin before installing, so no upgrade can slip in between and replace it.
            _local_pkg_pin "$pkg"
            sudo pacman -U --noconfirm "$PKGDEST/$pkg"-[0-9]*.pkg.tar.* || {
                track_warning "$pkg: installing the patched $ver failed — keeping $installed"; return 0; }
            print_success "$pkg: patched $ver installed — restart its users to load it"
            return 0
            ;;
    esac
    mkdir -p "${state%/*}"
    printf '%s\n%s\n' "$key" "$verdict" >"$state"
    _local_pkg_report "$pkg" "$ver" "$verdict" "$installed"
}

reconcile_local_packages() {
    [ -d "$LOCAL_PACKAGES_DIR" ] || return 0
    # sudo and makepkg -s both prompt — the update_system_packages judgement.
    if [ ! -t 0 ]; then
        print_info "Not a terminal — skipping the patched packages"
        return 0
    fi
    local dir pkg
    for dir in "$LOCAL_PACKAGES_DIR"/*/; do
        pkg="$(basename "$dir")"
        # Called in an || list on purpose: that suspends set -e for the whole
        # function, so an offline gitlab, a declined sudo or a failed pacman
        # costs this one package a warning instead of ending `dots update`.
        _local_pkg_sync "$pkg" ||
            track_warning "$pkg: the patched package step failed — see above"
    done
}
