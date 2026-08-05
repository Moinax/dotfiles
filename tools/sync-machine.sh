#!/bin/bash
# dots update — bring this machine in line with the repo.
#
# The counterpart to `dots setup`, and the command you actually run day to day.
# Setup answers "what should this machine be?" once, interactively, and is not
# built to be re-run: it re-asks every question, so a laptop that has never
# wanted the gaming group has to say so again every single time.
#
# This asks the much smaller question "what has the repo gained since this
# machine last agreed with it?" — anchored on SYNCED_COMMIT in the machine
# profile. That anchor is what makes the difference: without it the only
# question available is "what is missing here?", which cannot tell a package
# that is new from one that was removed on purpose, and so re-offers the removed
# one forever.
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_DIR="$DOTFILES_DIR/packages"
GROUPS_DIR="$PACKAGES_DIR/groups"

source "$DOTFILES_DIR/install/lib/common.sh"
source "$DOTFILES_DIR/install/lib/detect.sh"
source "$DOTFILES_DIR/install/lib/post-apply.sh"

install_interrupt_trap

DISTRO=$(detect_distro)
DISTRO_FAMILY=$(get_distro_family "$DISTRO")
load_distro_lib || exit 1

# Filled by pull_repo / resolve_base, read by the phases after them.
BASE_COMMIT=""        # what this machine last agreed with; "" = no delta known
CHANGED_FILES=()      # BASE_COMMIT..HEAD, empty when BASE_COMMIT is ""
# A package left behind is tracked by mark_sync_shortfall/sync_shortfall in
# common.sh, not by a flag of this script's own: `dots setup` needed the same
# judgement and had drawn the opposite conclusion from it.

# ── Phase 1: the repo ────────────────────────────────────────────────────────

# Pull, but never at the cost of uncommitted work. The dotfiles are reviewed
# with hunk, which watches *unstaged* changes — silently stashing them out from
# under a review in progress is not a reasonable default, so a dirty tree asks.
pull_repo() {
    print_header "Repository"

    if ! git -C "$DOTFILES_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        print_warning "$DOTFILES_DIR is not a git checkout — skipping pull"
        return 0
    fi

    local branch
    branch=$(git -C "$DOTFILES_DIR" symbolic-ref --short -q HEAD) || {
        print_warning "Detached HEAD — skipping pull"
        return 0
    }

    local pull_args=(pull --rebase --quiet)
    if [ -n "$(git -C "$DOTFILES_DIR" status --porcelain)" ]; then
        print_warning "Uncommitted changes in $DOTFILES_DIR:"
        git -C "$DOTFILES_DIR" status --short | sed 's/^/  /'
        echo ""
        if confirm_or_abort "Stash them, pull, then restore?"; then
            pull_args=(-c rebase.autoStash=true "${pull_args[@]}")
        else
            print_info "Keeping local state — skipping pull"
            return 0
        fi
    fi

    if git -C "$DOTFILES_DIR" "${pull_args[@]}" 2>/dev/null; then
        print_success "Repository up to date ($branch)"
    else
        print_warning "Pull failed — continuing with the checkout as it is"
    fi
}

# Where to diff from. A missing or unreachable anchor is not an error: it just
# means this run has no delta to offer and re-anchors instead.
resolve_base() {
    local synced
    synced=$(profile_get SYNCED_COMMIT)

    if [ -z "$synced" ]; then
        print_info "No sync anchor yet — recording this commit as the baseline."
        print_info "Run 'dots packages sync' once to catch up on anything already missing."
        return 0
    fi

    # A rebase can rewrite the commit this machine was anchored on — routine
    # here, where history is kept linear by rebasing onto origin/main.
    if ! git -C "$DOTFILES_DIR" cat-file -e "${synced}^{commit}" 2>/dev/null; then
        print_warning "Last synced commit ${synced:0:8} is gone (rewritten history) — re-anchoring"
        return 0
    fi

    BASE_COMMIT="$synced"
    mapfile -t CHANGED_FILES < <(
        git -C "$DOTFILES_DIR" diff --name-only "$BASE_COMMIT" HEAD 2>/dev/null || true)
}

# ── Phase 2: packages the repo gained ────────────────────────────────────────

# Every package declared for this machine — base plus every enabled group — as
# it reads in a given commit. Called once for the anchor and once for HEAD; the
# difference is what the repo gained.
#
# Parsed from a worktree of that commit rather than diffed textually, so the
# answer comes from `base_desired_packages`/`get_group_packages` — the same pair
# `dots packages sync` and the manage view ask — and a reformatted list is not
# mistaken for new packages.
#
# Emits "pkg<TAB>group-file", the file being empty for a distro package and the
# declaring group's yaml for a custom_install entry. The caller needs that split
# anyway (the two have different install paths and different installed-checks),
# and carrying it out of here is what saves a second parse of every group file.
declared_packages_at() {
    local root="$1"
    local file pkg flag

    while IFS= read -r pkg; do
        [ -n "$pkg" ] && printf '%s\t\n' "$pkg"
    done < <(base_desired_packages "$root/packages")

    for file in "$root"/packages/groups/*.yaml; do
        [ -f "$file" ] || continue
        # Enabled-ness is a property of *this machine*, read from chezmoi data,
        # so it is judged on the group's name and not on the old file's content.
        group_enabled "$file" || continue

        # group_declared_packages already knows which names are custom_install
        # entries — it had to, to build its list. Asking again with a second
        # parse_custom_install_names was the same yq work twice per group, and the
        # only thing this needs on top is *which file* declared it.
        while IFS=$'\t' read -r pkg flag; do
            [ -n "$pkg" ] && printf '%s\t%s\n' "$pkg" "${flag:+$file}"
        done < <(group_declared_packages "$file")
    done
}

# Groups this machine has never answered for: a group file exists and chezmoi
# data holds no flag for it at all — neither true nor false.
#
# Keyed on the missing flag rather than on "new since the anchor", because that
# same condition covers two cases with one question. A group genuinely added
# upstream is the obvious one. The other is repair: the installer used to write
# its flags from a hardcoded list, so groups added to packages/groups/ after
# that list was written got installed and never recorded — `biometric` and
# `security` were installed and running while every `group_enabled` caller read
# them as disabled. Anchoring this on the diff would have left those machines
# broken forever, since their flags did not go missing at any particular commit.
#
# Answering either way writes the flag, so nothing is ever asked twice.
reconcile_group_flags() {
    local -a unanswered=()
    local file group_id
    for file in "$GROUPS_DIR"/*.yaml; do
        [ -f "$file" ] || continue
        # The same hardware gate the installer and the manage view consult, so a
        # laptop with no fingerprint reader is not asked to record `biometric`,
        # a group nothing on it could install.
        group_hardware_available "$file" || continue
        group_id=$(get_group_id "$file")
        [ -z "$(chezmoi_data_get "$(get_chezmoi_flag "$group_id")")" ] || continue
        unanswered+=("$group_id")
    done

    [ ${#unanswered[@]} -gt 0 ] || return 0

    print_header "Unrecorded Groups"

    ensure_installed_index
    local group flag desc pkg total have state
    for group in "${unanswered[@]}"; do
        desc=$(yq -r '.description // .name // ""' "$GROUPS_DIR/$group.yaml" 2>/dev/null || true)

        # Whether the machine already runs it decides the question being asked:
        # "do you want this?" for something absent, "shall I record what you
        # already have?" for something installed behind the tooling's back.
        total=0; have=0
        while IFS= read -r pkg; do
            [ -n "$pkg" ] || continue
            total=$((total + 1))
            [ -n "${INSTALLED_SET[${pkg#*/}]:-}" ] && have=$((have + 1))
        done < <(parse_packages "$GROUPS_DIR/$group.yaml" "$DISTRO_FAMILY" 2>/dev/null || true)

        state="not installed here"
        if [ "$total" -gt 0 ] && [ "$have" -eq "$total" ]; then
            state="already installed here ($have/$total)"
        elif [ "$have" -gt 0 ]; then
            state="partly installed here ($have/$total)"
        fi

        echo ""
        print_info "$group${desc:+ — $desc}"
        print_info "  $state"
        flag=$(get_chezmoi_flag "$group")
        # confirm_or_abort matters most here: answering either way writes the flag
        # and the question is never put again, so a cancel read as "no" would
        # record a group as disabled permanently on the strength of an Esc.
        if confirm_or_abort "Record '$group' as enabled on this machine?"; then
            chezmoi_data_set "$flag" true
            print_success "$flag = true"
        else
            chezmoi_data_set "$flag" false
            print_info "$flag = false — it will not be asked again"
        fi
    done
}

# The delta scan: everything between "what has the repo gained?" and the answer.
# Emits "pkg<TAB>group-file" per candidate, carrying the custom_install split out
# so the caller does not walk the yaml a second time to rebuild it.
#
# Silent and several seconds long — a `git archive` export, two full yq walks over
# packages/, a package-manager query and one installed-check per custom entry — so
# it is meant to be run through spin_capture. That is also why it prints nothing
# itself: a failure to read the anchor comes back as exit status 1 and the caller
# words the warning, since the spinner swallows this pass's stderr. INSTALLED_SET
# stays local to the background pass, and nothing after the scan needs it.
new_package_candidates() {
    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064  # $tmp must expand now, not at trap time
    trap "rm -rf '$tmp'" RETURN

    git -C "$DOTFILES_DIR" archive "$BASE_COMMIT" packages 2>/dev/null \
        | tar -x -C "$tmp" || return 1

    local -A was=()
    local pkg group_file
    while IFS=$'\t' read -r pkg group_file; do
        [ -n "$pkg" ] && was["$pkg"]=1
    done < <(declared_packages_at "$tmp")

    # New = declared now, not declared then, not already on the machine.
    ensure_installed_index
    local -A seen=()
    while IFS=$'\t' read -r pkg group_file; do
        [ -z "$pkg" ] && continue
        [ -n "${seen[$pkg]:-}" ] && continue
        seen["$pkg"]=1
        [ -n "${was[$pkg]:-}" ] && continue
        if [ -n "$group_file" ]; then
            is_custom_install_installed "$group_file" "$pkg" && continue
        else
            [ -n "${INSTALLED_SET[${pkg#*/}]:-}" ] && continue
        fi
        printf '%s\t%s\n' "$pkg" "$group_file"
    done < <(declared_packages_at "$DOTFILES_DIR")
}

# Install what the repo gained and this machine does not have. Deliberately not
# "everything missing": that is `dots packages sync`, and it cannot distinguish
# a new package from one you removed.
sync_new_packages() {
    [ -n "$BASE_COMMIT" ] || return 0

    # Nothing under packages/ moved — skip the worktree export entirely.
    local touched=false f
    for f in "${CHANGED_FILES[@]}"; do
        case "$f" in packages/*) touched=true; break ;; esac
    done
    $touched || return 0

    print_header "New Packages"

    local found=""
    if ! spin_capture found "Comparing packages against ${BASE_COMMIT:0:8}..." \
            new_package_candidates; then
        print_warning "Could not read packages/ at ${BASE_COMMIT:0:8} — skipping the delta"
        # A shortfall, not a clean skip: the scan is what decides whether anything
        # is missing, so a scan that did not run leaves that unknown. Advancing the
        # anchor here would move it past every package the repo gained since it,
        # and nothing would ever offer them again.
        mark_sync_shortfall
        return 0
    fi

    local -A custom_of=()
    local -a candidates=()
    local pkg group_file
    while IFS=$'\t' read -r pkg group_file; do
        [ -n "$pkg" ] || continue
        candidates+=("$pkg")
        [ -n "$group_file" ] && custom_of["$pkg"]="$group_file"
    done <<< "$found"

    if [ ${#candidates[@]} -eq 0 ]; then
        print_success "No new packages since ${BASE_COMMIT:0:8}"
        return 0
    fi

    print_info "Added to the dotfiles since ${BASE_COMMIT:0:8} (${#candidates[@]}):"
    printf '  %s\n' "${candidates[@]}"
    echo ""
    if ! confirm_or_abort "Install them?"; then
        print_info "Skipped — they will be offered again next time"
        mark_sync_shortfall
        return 0
    fi

    local -a distro_pkgs=()
    for pkg in "${candidates[@]}"; do
        if [ -n "${custom_of[$pkg]:-}" ]; then
            # install_custom_pkg marks the shortfall itself on both of its
            # not-installed paths, so nothing to record here.
            install_custom_pkg "${custom_of[$pkg]}" "$pkg"
        else
            distro_pkgs+=("$pkg")
        fi
    done

    # Only reached for a shortfall this machine can carry: an AUR build that broke,
    # a package the repo names and the mirrors no longer have. Those warn, let the
    # configs and tools land, and hold the anchor back through the shortfall flag
    # install_packages already set — whereas a stale package database means nothing
    # can be installed at all, and install_packages ends the run itself rather than
    # returning here (see _recover_stale_db in arch.sh).
    #
    # Unguarded, this was `[ n -gt 0 ] && install_packages …` — a bare failing
    # command under `set -e`, so *every* failure exited mid-phase with no chezmoi
    # apply, no tool refresh, no surface reloads and no anchor, and did it silently,
    # since the exit looked like a clean end. Which of the two happens is now a
    # decision rather than an accident of shell semantics.
    if [ ${#distro_pkgs[@]} -gt 0 ]; then
        install_packages "${distro_pkgs[@]}" \
            || print_warning "Some new packages could not be installed"
    fi
    return 0
}

# ── Phase 4: tools ───────────────────────────────────────────────────────────

update_tools() {
    # 130 is the child telling us the user stopped it, and it is the one status that
    # must not become a warning: gum sends no signal on Esc, so our own INT trap
    # never fires and swallowing this applied the dotfiles and stamped the anchor
    # for a run the user had just aborted. Anything else really is "a tool failed".
    #
    # `if` rather than `&&` on each test: a bare failing && list is what `set -e`
    # exits the whole script on.
    local rc=0
    "$DOTFILES_DIR/tools/manage-updates.sh" || rc=$?
    if [ "$rc" -eq 130 ]; then
        exit 130
    elif [ "$rc" -ne 0 ]; then
        print_warning "Some tools could not be updated"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

do_sync() {
    if ! machine_is_managed; then
        print_error "This machine has not been set up yet"
        print_info "Run 'dots setup' first — there is nothing to bring up to date."
        return 1
    fi

    pull_repo
    resolve_base
    reconcile_group_flags
    sync_new_packages

    print_header "Dotfiles"
    # Not apply_dotfiles: the tool refresh has to land between the apply and the
    # reconciliation, so that waybar restarts after the binaries its modules run.
    chezmoi_apply
    update_tools
    # The file list decides which surfaces need reconciling; an unanchored run
    # passes none, which means "reconcile everything".
    run_post_apply "${CHANGED_FILES[@]}"

    # record_synced_state declines on its own while a package shortfall is
    # outstanding — mark_sync_shortfall in common.sh carries the why. Everything
    # above this line has still happened, so the cost is one re-offer next run.
    record_synced_state

    local head
    head=$(profile_get SYNCED_COMMIT)
    echo ""
    if sync_shortfall; then
        print_warning "Configs and tools are up to date, but packages were left behind"
        print_info "Still anchored at ${head:0:8} — they will be offered again next 'dots update'"
    else
        print_success "Machine in sync${head:+ at ${head:0:8}}"
    fi
}

usage() {
    cat <<'EOF'
Usage: dots update [command]

Brings this machine in line with the dotfiles repo: pulls, offers what the repo
has gained since the last sync, applies the configs, refreshes the tools, and
reloads the surfaces that need it.

Commands:
  (none)      Run the full sync
  tools       Only refresh curl/npm/cargo tools and apps (see 'dots update tools help')
  help        Show this help message
EOF
}

case "${1:-}" in
    ""|sync)        do_sync ;;
    tools)          shift; "$DOTFILES_DIR/tools/manage-updates.sh" "$@" ;;
    help|--help|-h) usage ;;
    *)              usage; exit 1 ;;
esac
