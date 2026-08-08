#!/bin/bash
# dots update — bring this machine in line with the repo.
#
# The counterpart to `dots setup`, and the command you actually run day to day.
# Setup answers "what should this machine be?" once, interactively, and is not
# built to be re-run: it re-asks every question, so a laptop that has never
# wanted the gaming group has to say so again every single time.
#
# This asks the much smaller question "what has the repo changed since this
# machine last agreed with it?" — anchored on SYNCED_COMMIT in the machine
# profile. That anchor is what makes the difference: without it the only
# question available is "what is missing here?", which cannot tell a package
# that is new from one that was removed on purpose, and so re-offers the removed
# one forever.
#
# The anchor is what makes the *other* direction possible too. Knowing which
# commit this machine agreed with is what turns "the repo no longer declares
# rofi" into a question worth asking, where a plain audit of everything
# undeclared would sweep up half of what you ever installed by hand.
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

# The delta scan: everything between "what has the repo changed?" and the answer.
# Emits one "op<TAB>pkg<TAB>detail" row per candidate, op being `add` or `drop`.
# `detail` is the declaring group file for an `add` (empty for a distro package,
# so the caller does not walk the yaml again to rebuild the custom_install split)
# and the literal `custom` for a `drop` — the file that declared a dropped entry
# is in the export below, which is gone by the time the caller reads this.
#
# Both directions come off the same export and the same pair of walks. They are
# each other's complement, so asking the question backwards a second time would
# mean paying the whole scan twice for an answer already in memory. That is also
# why `drop` rows carry the *installed* name rather than the declared one: the
# resolution needs the alias index this pass already builds.
#
# Silent and several seconds long — a `git archive` export, two full yq walks over
# packages/, a package-manager query and one installed-check per custom entry — so
# it is meant to be run through spin_capture. That is also why it prints nothing
# itself: a failure to read the anchor comes back as exit status 1 and the caller
# words the warning, since the spinner swallows this pass's stderr. The indexes
# stay local to the background pass, and nothing after the scan needs them.
package_delta() {
    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064  # $tmp must expand now, not at trap time
    trap "rm -rf '$tmp'" RETURN

    git -C "$DOTFILES_DIR" archive "$BASE_COMMIT" packages 2>/dev/null \
        | tar -x -C "$tmp" || return 1

    local -A was=() was_file=()
    local pkg group_file
    while IFS=$'\t' read -r pkg group_file; do
        [ -n "$pkg" ] || continue
        was["$pkg"]=1
        was_file["$pkg"]="$group_file"
    done < <(declared_packages_at "$tmp")

    # `real_of` answers both halves at once: a declared name that maps to nothing
    # is not on this machine (which is what the install side asks), and one that
    # maps to something yields the name pacman actually holds (which is what the
    # removal side needs). It replaces ensure_installed_index here for that reason
    # — the flat set could only answer the first question.
    # One row per name, collisions already settled by the distro lib — a plain
    # fold is all that is left here.
    local -A real_of=()
    local alias real
    while IFS=$'\t' read -r alias real; do
        [ -n "$alias" ] && real_of["$alias"]="$real"
    done < <(installed_package_aliases)

    # New = declared now, not declared then, not already on the machine.
    local -A seen=()
    while IFS=$'\t' read -r pkg group_file; do
        [ -z "$pkg" ] && continue
        [ -n "${seen[$pkg]:-}" ] && continue
        seen["$pkg"]=1
        [ -n "${was[$pkg]:-}" ] && continue
        if [ -n "$group_file" ]; then
            is_custom_install_installed "$group_file" "$pkg" && continue
        else
            [ -n "${real_of[${pkg#*/}]:-}" ] && continue
        fi
        printf 'add\t%s\t%s\n' "$pkg" "$group_file"
    done < <(declared_packages_at "$DOTFILES_DIR")

    # Dropped = declared then, not declared now, and still here. `seen` holds the
    # whole current declaration by now, so inverting the test costs no third walk.
    #
    # Which names left the yaml is pure array work, so it is settled before the
    # install-reason query rather than after: a run where the repo only *gained*
    # packages — the common one by far — then never spawns that query at all.
    local -a maybe_dropped=()
    for pkg in "${!was[@]}"; do
        [ -n "${seen[$pkg]:-}" ] || maybe_dropped+=("$pkg")
    done
    [ ${#maybe_dropped[@]} -gt 0 ] || return 0

    local -A explicit=()
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && explicit["$pkg"]=1
    done < <(list_explicit_packages)

    for pkg in "${maybe_dropped[@]}"; do
        group_file="${was_file[$pkg]}"
        if [ -n "$group_file" ]; then
            # A custom_install entry has an install_cmd and no counterpart, so it
            # is reported and never removed — the same call `dots packages` makes
            # when its manage view is asked to remove one.
            is_custom_install_installed "$group_file" "$pkg" && printf 'drop\t%s\tcustom\n' "$pkg"
            continue
        fi
        real="${real_of[${pkg#*/}]:-}"
        [ -n "$real" ] || continue
        # Installed as a dependency means something else is holding it here, and
        # a yaml no longer naming it is not a reason to take it away.
        [ -n "${explicit[$real]:-}" ] || continue
        printf 'drop\t%s\t\n' "$real"
    done
}

# Both halves of the delta: install what the repo gained, offer to remove what it
# dropped. Deliberately not "everything missing / everything not declared" —
# that is `dots packages sync` and a whole-machine audit respectively, and
# neither can tell a package the repo changed its mind about from one you
# installed by hand.
#
# One scan, two questions, in that order: a replacement lands before the thing it
# replaces leaves, so a machine is never briefly without either.
sync_packages() {
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
            package_delta; then
        print_warning "Could not read packages/ at ${BASE_COMMIT:0:8} — skipping the delta"
        # A shortfall, not a clean skip: the scan is what decides whether anything
        # is missing, so a scan that did not run leaves that unknown. Advancing the
        # anchor here would move it past every package the repo gained since it,
        # and nothing would ever offer them again.
        mark_sync_shortfall
        return 0
    fi

    # Split by op and hand each half its own rows. Nothing more is done here:
    # the two questions parse what they were given, so neither reaches into this
    # scope for it. Bash would have allowed that — `local` is dynamically scoped,
    # so an argument-less callee can read a caller's arrays — but it is a
    # contract living only in a comment, and renaming an array here would leave
    # the other half silently reading nothing.
    local add_rows="" drop_rows=""
    local op pkg detail
    while IFS=$'\t' read -r op pkg detail; do
        [ -n "$pkg" ] || continue
        case "$op" in
            add)  add_rows+="${pkg}"$'\t'"${detail}"$'\n' ;;
            drop) drop_rows+="${pkg}"$'\t'"${detail}"$'\n' ;;
        esac
    done <<< "$found"

    install_new_packages "$add_rows"
    remove_dropped_packages "$drop_rows"
}

# The "add" half: what the repo gained and this machine does not have. Takes the
# scan's `add` rows verbatim — "pkg<TAB>group-file", the file set only for a
# custom_install entry, which is the split the walk already carried out.
install_new_packages() {
    local -A custom_of=()
    local -a candidates=()
    local pkg group_file
    while IFS=$'\t' read -r pkg group_file; do
        [ -n "$pkg" ] || continue
        candidates+=("$pkg")
        [ -n "$group_file" ] && custom_of["$pkg"]="$group_file"
    done <<< "$1"

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

# The "drop" half: packages the repo declared at the anchor, declares no longer,
# and this machine still has. Takes the scan's `drop` rows verbatim —
# "pkg<TAB>kind", kind being `custom` for an entry installed by a bespoke
# command and empty for a distro package.
#
# **A declined removal does not mark a shortfall, and that asymmetry is the
# point.** The flag means "this machine is missing something the repo asks for",
# which a kept package is not; and holding the anchor back would re-ask the
# question at every single update. For an install "not now" is a fair reading of
# no — the package is still wanted and will be offered again. For a removal, no
# means *keep it*, and that is an answer, not a postponement. Letting the anchor
# advance past the commit that dropped the package is what makes it stick.
remove_dropped_packages() {
    local -a dropped=() dropped_custom=()
    local pkg kind
    while IFS=$'\t' read -r pkg kind; do
        [ -n "$pkg" ] || continue
        if [ "$kind" = custom ]; then dropped_custom+=("$pkg"); else dropped+=("$pkg"); fi
    done <<< "$1"

    if [ ${#dropped[@]} -eq 0 ] && [ ${#dropped_custom[@]} -eq 0 ]; then
        return 0
    fi

    print_header "Dropped Packages"

    # Reported rather than skipped silently: a curl-installed binary that nothing
    # declares any more is exactly the thing nobody remembers to clean up.
    if [ ${#dropped_custom[@]} -gt 0 ]; then
        warn_custom_uninstall "${dropped_custom[@]}"
        echo ""
    fi

    [ ${#dropped[@]} -gt 0 ] || return 0

    # pacman decides what is actually removable, not us. A first pass over the
    # whole set is the common case; when it refuses, the retry finds which
    # package is the one something else still requires instead of dropping the
    # entire batch on its account.
    local plan="" blocked=() keep=() p
    if ! plan=$(plan_removal "${dropped[@]}"); then
        for p in "${dropped[@]}"; do
            if plan_removal "$p" >/dev/null 2>&1; then keep+=("$p"); else blocked+=("$p"); fi
        done
        dropped=("${keep[@]}")
        plan=""
        if [ ${#dropped[@]} -gt 0 ]; then
            plan=$(plan_removal "${dropped[@]}") || plan=""
        fi
    fi

    if [ ${#blocked[@]} -gt 0 ]; then
        print_warning "Still required by something else, left alone (${#blocked[@]}): ${blocked[*]}"
    fi

    if [ ${#dropped[@]} -eq 0 ]; then
        print_info "Nothing removable"
        return 0
    fi

    # What -Rs would cascade to on top of the named packages. Shown separately
    # because it is the part the user did not ask for and cannot predict, and a
    # removal is the one thing here that cannot be undone by re-running.
    local -A named=()
    local -a extra=()
    for p in "${dropped[@]}"; do named["$p"]=1; done
    while IFS= read -r p; do
        [ -n "$p" ] && [ -z "${named[$p]:-}" ] && extra+=("$p")
    done <<< "$plan"

    print_info "Dropped from the dotfiles since ${BASE_COMMIT:0:8} (${#dropped[@]}):"
    printf '  %s\n' "${dropped[@]}"
    if [ ${#extra[@]} -gt 0 ]; then
        local noun="dependencies"
        if [ ${#extra[@]} -eq 1 ]; then noun="dependency"; fi
        echo ""
        print_info "Plus ${#extra[@]} $noun nothing else needs:"
        printf '  %s\n' "${extra[@]}"
    fi
    echo ""
    if ! confirm_or_abort "Remove them?"; then
        print_info "Kept — the anchor moves on, so this is not asked again"
        return 0
    fi

    # Guarded for the same reason the install above is: a failing removal must
    # not take the chezmoi apply, the tool refresh and the reloads down with it.
    remove_packages "${dropped[@]}" \
        || print_warning "Some packages could not be removed"
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
    sync_packages

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
has gained since the last sync and what it has dropped, applies the configs,
refreshes the tools, and reloads the surfaces that need it.

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
