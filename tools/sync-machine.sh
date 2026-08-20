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
source "$DOTFILES_DIR/install/lib/dns-encrypted.sh"
source "$DOTFILES_DIR/install/lib/login-wallpaper.sh"
source "$DOTFILES_DIR/install/lib/post-apply.sh"

install_interrupt_trap

DISTRO=$(detect_distro)
DISTRO_FAMILY=$(get_distro_family "$DISTRO")
load_distro_lib || exit 1

# Filled by resolve_base, read by the phases after it.
BASE_COMMIT=""        # what this machine last agreed with; "" = no delta known
CHANGED_FILES=()      # BASE_COMMIT..HEAD, empty when BASE_COMMIT is ""
# A package left behind is tracked by mark_sync_shortfall/sync_shortfall in
# common.sh, not by a flag of this script's own: `dots setup` needed the same
# judgement and had drawn the opposite conclusion from it.

# ── The repo ────────────────────────────────────────────────────────────────

# Pull, but never at the cost of uncommitted work. The dotfiles are reviewed
# with hunk, which watches *unstaged* changes — silently stashing them out from
# under a review in progress is not a reasonable default, so a dirty tree asks.
#
# **This is not part of the sync, and that separation is the point.** Bash parses
# a script before running it, so while the pull lived here every function in this
# file was the pre-pull one: a run that fetched a fix to `dots update` went on
# applying the old behaviour anyway, and the fix landed one run late. Not an
# academic cost — `python-pyqt6-webengine` was offered for *removal*, and
# removed, by the pre-pull walk that could not yet see a `requires_packages`, in
# the very run that pulled the commit teaching it to. Every other phase can be
# re-run; a removal cannot.
#
# `dots` therefore runs `sync-machine.sh pull`, waits for it to exit, and only
# then starts the sync — so everything the sync does is post-pull by
# construction, with no marker, no restart and no list of which paths matter.
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
    return 0
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

# ── The system ──────────────────────────────────────────────────────────────

# pacman and AUR still belong to the upgrade tools — this calls one, it does not
# reimplement one, and manage-updates.sh still covers only what they cannot see.
#
# It runs *before* the package delta on purpose: installing against a database a
# few days old asks the mirrors for versions they have already rebuilt, and every
# one 404s (that is what _recover_stale_db in arch.sh recovers from after the
# fact, and it now has one less reason to fire).
#
# Nothing here is forced. Whichever tool runs asks for its own confirmation, so
# there is no prompt of ours in front of it, and a refusal only skips this phase —
# the sync carries on to the packages, the apply and the tools. 130 is the user
# stopping the run, and is the one status that must end it, same as update_tools.
update_system_packages() {
    local updater
    updater=$(command -v cachy-update || command -v arch-update) || updater=""

    # Either path needs a sudo password and asks its own questions; under a pipe
    # or a cron there is nobody to answer, and it would sit on a prompt nobody
    # sees.
    if [ ! -t 0 ]; then
        print_info "Not a terminal — skipping the system update, run '$(basename "${updater:-paru}")' by hand"
        return 0
    fi

    print_header "System"
    local rc=0
    if [ -n "$updater" ]; then
        "$updater" || rc=$?
    else
        # No cachy-update here — plain Arch, EndeavourOS, Garuda. The distro layer
        # already owns "upgrade this system": update_system in
        # install/distros/arch.sh, the call `dots setup` opens with and the one
        # _recover_stale_db falls back on. `confirm` is the load-bearing argument —
        # it shows the transaction and lets you say no, which is this phase's whole
        # contract. Skipping instead left the machine that most needs a fresh
        # database, the one with no updater wrapper, as the only one we passed over.
        update_system confirm || rc=$?
    fi

    case "$rc" in
        0|4)  ;;  # cachy-update's 4 = "the update has been aborted", i.e. you said no
        130)  exit 130 ;;
        # paru and pacman have no code of their own for a refusal — declining the
        # transaction and failing it both exit 1 — so this line has to cover both
        # without accusing either. It is a note; the sync goes on regardless.
        *)    print_warning "System packages not upgraded (declined, or the upgrade failed — status ${rc})" ;;
    esac
}

# ── Packages the repo gained ────────────────────────────────────────────────

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
#
# **`requires_packages` counts as declared, and leaving it out is what made
# `dots update` uninstall a runtime the repo still asks for.** Moving
# `python-pyqt6-webengine` out of messaging's `packages:` and into the
# `requires_packages:` of the two chat shells changed nothing about whether the
# machine wants it — but this walk only saw the `packages:` key, so the name
# vanished from the HEAD set while remaining in the anchor's, and the drop half
# offered it for removal under the heading "Dropped from the dotfiles". It was
# removed, taking python-pyqt6 with it, and both launchers died on `import
# PyQt6` at their next start. Neither guard could have caught it: pacman's
# dependency graph does not know a Python script imports a module, and the
# confirmation prompt was asking about a list that was wrong.
declared_packages_at() {
    local root="$1"
    local file pkg flag rows

    while IFS= read -r pkg; do
        [ -n "$pkg" ] && printf '%s\t\n' "$pkg"
    done < <(base_desired_packages "$root/packages")

    for file in "$root"/packages/groups/*.yaml; do
        [ -f "$file" ] || continue
        # Enabled-ness is a property of *this machine*, read from chezmoi data,
        # so it is judged on the group's name and not on the old file's content.
        group_enabled "$file" || continue

        # One read, classified twice — the split group_declared_lists exists for.
        # group_declared_packages would be the same yq call over again just to
        # reach the prerequisite rows it drops on the floor.
        rows=$(group_declared_lists "$file")

        # classify_declared_rows already knows which names are custom_install
        # entries — it had to, to build its list. Asking again with a second
        # parse_custom_install_names was the same yq work twice per group, and the
        # only thing this needs on top is *which file* declared it.
        while IFS=$'\t' read -r pkg flag; do
            [ -n "$pkg" ] && printf '%s\t%s\n' "$pkg" "${flag:+$file}"
        done < <(printf '%s\n' "$rows" | classify_declared_rows)

        # Emitted with no group file, i.e. as distro packages, which is what they
        # are: pacman installs them and pacman can remove them. The custom-entry
        # column means "installed by a bespoke command, so it has no uninstall" —
        # a prerequisite is neither.
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && printf '%s\t\n' "$pkg"
        done < <(printf '%s\n' "$rows" | selected_requires_packages)
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
    local file group_id group_answer
    for file in "$GROUPS_DIR"/*.yaml; do
        [ -f "$file" ] || continue
        # The same hardware gate the installer and the manage view consult, so a
        # laptop with no fingerprint reader is not asked to record `biometric`,
        # a group nothing on it could install.
        group_hardware_available "$file" || continue
        group_id=$(get_group_id "$file")
        group_answer=$(chezmoi_data_get "$(get_chezmoi_flag "$group_id")")
        if [ -z "$group_answer" ]; then
            unanswered+=("$group_id")
            continue
        fi
        # Already-answered groups still need their per-app flags backfilled: the
        # machines that most need this are precisely the ones that answered long
        # ago, since only `dots setup` ever wrote those keys. Missing ones inherit
        # the group's recorded answer; existing ones are left alone.
        seed_custom_entry_flags "$file" "$group_answer"
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
            seed_custom_entry_flags "$GROUPS_DIR/$group.yaml" true
            print_success "$flag = true"
        else
            chezmoi_data_set "$flag" false
            seed_custom_entry_flags "$GROUPS_DIR/$group.yaml" false
            print_info "$flag = false — it will not be asked again"
        fi
    done
}

# Per-app flags for the group's `chezmoi_flag: true` custom entries, defaulted to
# the answer just given for the group itself.
#
# Only `dots setup` wrote these before, and it is the one command an existing
# machine never runs — so a machine that adopted a group here got the group flag
# and nothing else. That is not a gap the templates can paper over: they read the
# key directly, and chezmoi *errors* on a missing one rather than treating it as
# false, so `install_ai = true` with no `install_vibewatch` breaks every
# `chezmoi apply` on that machine outright. Seeding at the single writer fixes it
# for every template at once, instead of each gate carrying its own fallback.
#
# Never overwrites an answer already recorded — re-running must not undo a
# deliberate untick.
seed_custom_entry_flags() {
    local group_file="$1" default="$2" entry flag
    [ -f "$group_file" ] || return 0

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        flag=$(get_chezmoi_flag "$entry")
        [ -z "$(chezmoi_data_get "$flag")" ] || continue
        chezmoi_data_set "$flag" "$default"
        print_info "  $flag = $default"
    done < <(parse_custom_install_flag_entries "$group_file")
    return 0
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

# The prerequisites of every custom_install entry this machine keeps, that are
# not installed. Anchor-independent, unlike everything else in this phase, and
# that is the whole point: a `requires_packages` package that goes missing does
# so on the *machine*, at no commit at all, so a delta against SYNCED_COMMIT can
# never see it.
#
# Nothing else was going to notice either. An entry is revisited only when its
# `check` fails, and for the two chat shells the check is `[ -x
# ~/.local/bin/whatsapp ]` — a launcher chezmoi puts there whether or not its
# runtime exists. So the entry reads as done forever, `install_custom_requires`
# is never reached again, and the machine sits with a launcher that cannot
# start. The repair has to be its own question, asked off the declaration rather
# than off the check.
#
# Runs before sync_packages so the two cannot ask twice about the same package:
# the delta's install half skips anything already on the machine, and by then
# this has either put it there or been declined.
reconcile_custom_requires() {
    # grep before yq, as reconcile_declared_services does: three group files
    # declare the key and the rest cost nothing. Anchored to the start of the
    # line so the prose mentioning `requires_packages` in ai.yaml's and
    # messaging.yaml's comments does not drag those files through a parse.
    local -a declaring=()
    mapfile -t declaring < <(grep -l '^[[:space:]]*requires_packages:' "$GROUPS_DIR"/*.yaml 2>/dev/null)
    [ ${#declaring[@]} -gt 0 ] || return 0

    local -a want=()
    local file
    for file in "${declaring[@]}"; do
        group_enabled "$file" || continue
        mapfile -t -O "${#want[@]}" want \
            < <(group_declared_lists "$file" | selected_requires_packages)
    done
    [ ${#want[@]} -gt 0 ] || return 0

    ensure_installed_index
    local -A seen=()
    local -a missing=()
    local pkg
    for pkg in "${want[@]}"; do
        [ -n "$pkg" ] && [ -z "${seen[$pkg]:-}" ] || continue
        seen["$pkg"]=1
        [ -n "${INSTALLED_SET[${pkg#*/}]:-}" ] || missing+=("$pkg")
    done
    [ ${#missing[@]} -gt 0 ] || return 0

    print_header "Missing Prerequisites"
    print_info "Required by apps this machine keeps, absent from it (${#missing[@]}):"
    printf '  %s\n' "${missing[@]}"
    echo ""
    if ! confirm_or_abort "Install them?"; then
        # No shortfall: the anchor has no say in whether this is asked again.
        # The question comes off the machine's own state, so it returns by
        # itself at the next update for as long as the package is missing.
        print_info "Skipped — run 'dots update' again to be offered them"
        return 0
    fi

    install_packages "${missing[@]}" \
        || print_warning "Some prerequisites could not be installed"
    return 0
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
    #
    # CHANGED_FILES is the git diff BASE_COMMIT..HEAD, so this is also what makes
    # an uncommitted packages/ edit a no-op: package_delta below reads the live
    # checkout, working tree and all, but only a committed change ever gets it
    # that far. Deliberate — the anchor is a commit, so "since when" is only
    # answerable for committed state — but silent, and it reads as a bug from the
    # outside: you edit a yaml, run the command whose job is to act on it, and it
    # prints nothing.
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

# Every service the repo declares for this machine — base.yaml's and every
# enabled group's, system and user — that is not enabled, offered in one prompt.
#
# Scoped to base at first, which was a notch too narrow: `enable_selected_services`
# is installer-only, `sync_group_after_change` fires only for groups a *package*
# change touched (so a group that merely gained a service is never visited), and
# `start_user_services_after_apply` deliberately starts without ever enabling. So
# nothing enabled a group's newly declared service on an existing machine — which
# made hyprland's own `user_services: vicinae.service` inert everywhere but a
# fresh install, working only by the coincidence that vicinae-bin ships a systemd
# preset. That coincidence is exactly what declaring it was supposed to replace.
#
# Offered rather than enabled outright: the system half needs sudo, and a
# `dots update` that starts asking for a root password without saying why is
# worse than a prompt. Declining is not a shortfall — the anchor should not
# freeze over a service the user chose to leave off.
reconcile_declared_services() {
    command_exists systemctl || return 0

    # grep before yq: eight group files, two declare a block-form list, and yq is
    # ~170ms of interpreter start each. `services: []` does not match `^services:$`,
    # so the groups that declare nothing cost nothing.
    local -a declaring=()
    mapfile -t declaring < <(grep -l '^services:$\|^user_services:$' "$GROUPS_DIR"/*.yaml 2>/dev/null)

    local -a want_system=() want_user=()
    mapfile -t want_system < <(base_desired_services "$DOTFILES_DIR/packages")

    local file
    for file in "${declaring[@]}"; do
        group_enabled "$file" || continue
        mapfile -t -O "${#want_system[@]}" want_system < <(parse_services "$file")
        mapfile -t -O "${#want_user[@]}"   want_user   < <(parse_user_services "$file")
    done

    local -a missing_system=() missing_user=()
    [ ${#want_system[@]} -gt 0 ] \
        && mapfile -t missing_system < <(printf '%s\n' "${want_system[@]}" | services_with_state system no)
    [ ${#want_user[@]} -gt 0 ] \
        && mapfile -t missing_user < <(printf '%s\n' "${want_user[@]}" | services_with_state user no)

    local -a missing=("${missing_system[@]}" "${missing_user[@]}")
    [ ${#missing[@]} -gt 0 ] || return 0

    print_header "Declared Services"
    print_info "Declared by the repo but not enabled here: ${missing[*]}"
    if confirm_or_abort "Enable them?"; then
        [ ${#missing_system[@]} -gt 0 ] && for_each_service enable_service      "${missing_system[@]}"
        [ ${#missing_user[@]}   -gt 0 ] && for_each_service enable_user_service "${missing_user[@]}"
    else
        print_info "Skipped — run 'dots update' again to be offered them"
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

# ── DNS ─────────────────────────────────────────────────────────────────────

# The two files behind encrypted DNS — see install/lib/dns-encrypted.sh, which
# both this and `dots setup` call.
#
# Same shape as reconcile_login_wallpaper below, and for the same reason: setup
# is not re-run, so a machine that already existed when this landed would never
# get it. The trigger is machine state and never CHANGED_FILES — the anchor moves
# past the commit long before anyone wonders why their ISP still answers every
# lookup, and unlike a black lock screen this failure has no symptom at all.
#
# Reading the *content* rather than mere existence is what makes changing a
# resolver here reach machines that already carry the old drop-in.
reconcile_encrypted_dns() {
    encrypted_dns_needs_setup || return 0

    # sudo prompts for a password of its own, and under a pipe or a cron there is
    # nobody to type it — the same judgement update_system_packages makes.
    if [ ! -t 0 ]; then
        print_info "Not a terminal — skipping the encrypted DNS setup"
        return 0
    fi

    # No confirmation in front of this, for the reason spelled out at
    # reconcile_login_wallpaper: sudo already asks a question with a way out in
    # it, and two file writes plus a daemon reload is not a transaction worth a
    # second one.
    print_header "Encrypted DNS"
    print_info "DNS still goes to whatever resolver this network handed out — moving it to TLS (needs sudo)"
    apply_encrypted_dns || return 0
}

# ── The lock and login screens ──────────────────────────────────────────────

# The two privileged steps behind /var/lib/wallpaper/current — see
# install/lib/login-wallpaper.sh, which both this and `dots setup` call.
#
# Here because setup is not re-run: an already-set-up machine that merely pulled
# the feature got only the half of it that is a dotfile. The trigger is therefore
# machine state and never CHANGED_FILES — the anchor moves past the commit that
# ships a step like this long before anyone notices the step never ran. Which
# other installer-only steps have the same shape is in
# .claude/rules/sync-machine.md.
reconcile_login_wallpaper() {
    install_purpose_is desktop || return 0
    login_wallpaper_needs_setup || return 0

    # sudo prompts for a password of its own, and under a pipe or a cron there is
    # nobody to type it — the same judgement update_system_packages makes.
    #
    # Last of the three guards rather than first, though it is the only free one:
    # ahead of them it would announce a skip on every non-interactive run of a
    # machine that needs nothing. The ~9ms it costs to find that out (a
    # chezmoi.toml grep, one kreadconfig6) is paid once per `dots update`, not per
    # unit of anything, so quiet is worth more than the milliseconds here.
    if [ ! -t 0 ]; then
        print_info "Not a terminal — skipping the login wallpaper setup"
        return 0
    fi

    # No confirmation in front of this. sudo asks for a password, which is the
    # same question with a way out already built in, and the alternative to
    # answering it is a lock screen that stays black — there is no second thing
    # the machine could sensibly do. `install -d` and two config writes on a
    # machine that is already missing them is not a transaction worth a prompt.
    print_header "Login Wallpaper"
    print_info "The lock and login screens have no wallpaper of their own yet — publishing it (needs sudo)"
    apply_login_wallpaper || return 0
}

# ── Tools ───────────────────────────────────────────────────────────────────

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

# ── Forks ───────────────────────────────────────────────────────────────────

# Emits `repo<TAB>branch<TAB>behind<TAB>unpushed<TAB>command` for every fork with
# something to say. `behind` is a count, or `rebase`, or `-` when the fork's own
# branch is missing here; `unpushed` is `yes`/`no`, or `-` where it was never
# measured — which is not the same as `no`, and rendering it as one is how a
# fork mid-rebase with unpublished work reads as fully published.
#
# The `upstream` remote *is* the registry. A checkout that has one is a fork of
# something, so nothing has to be declared here for the next one to be picked up
# — which is the whole reason this is not a list of projects in the dotfiles.
#
# Report only, deliberately: a rebase stops on conflicts and wants a human, and
# by the time this runs the sync has applied its configs and stamped its anchor.
# The command it names is the repo's own, because rebasing is rarely the whole
# job — t3code has to rebuild and reinstall an AppImage afterwards, which only
# `t3fork` knows how to do.
#
# Prints nothing but its answer: it is meant to be run through spin_capture,
# which discards the pass's stderr.
fork_drift() {
    # dev-projects owns the project tree — its root, and the convention for what
    # counts as a checkout in it. Asking it is what keeps a machine with
    # DEV_PROJECTS_ROOT set from being invisible here.
    local root
    root="$(dev-projects root 2>/dev/null)" || root="$HOME/Projects"
    [ -d "$root" ] || return 0

    local repo candidate ref tip behind cmd
    while IFS= read -r repo; do
        git -C "$repo" remote get-url upstream >/dev/null 2>&1 || continue

        # Both of the fork's own answers, read once, before anything reaches the
        # network. Which branch carries its patches, and what brings it up to
        # date — the same two keys `t3fork` writes on every run.
        #
        # `HEAD` is only a sane default for the branch: a fork maintained by
        # rebasing one branch leaves every other branch stale on purpose, so
        # counting whatever happens to be checked out measures a branch nobody
        # maintains. t3code sat on a `main` five months old and was reported 1456
        # behind — a number about a branch `t3fork` never touches. The command
        # has no default this early, because the only one worth printing names
        # the upstream ref, which the fetch below has not resolved yet.
        tip=$(git -C "$repo" config --get dotfiles.forkBranch) || tip=""
        [ -n "$tip" ] || tip=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null) || tip="HEAD"
        cmd=$(git -C "$repo" config --get dotfiles.forkUpdate) || cmd=""

        # The two states this cannot measure, both answered from local files, so
        # neither pays for the fetch below — a fork stuck in either of them is
        # stuck until somebody acts, which means paying it on *every* run.
        #
        # A rebase stopped on a conflict is the subtler one. Git only moves the
        # branch ref when the rebase *completes*, so the tip still points where
        # it did before the attempt and the count comes out identical: the fork
        # would be reported exactly as it was, next to a command that now refuses
        # to run, with nothing saying the working tree is sitting in conflict.
        # The missing branch is the same failure by another route. In both, what
        # has to be avoided is a plausible number.
        #
        # `--path-format=absolute` is load-bearing: --git-path alone answers
        # relative to the repo (".git/rebase-merge"), and this walk runs from
        # wherever `dots update` was started, so the plain form tested a path
        # under the *caller's* cwd and never found one. It read as "no rebase
        # here" for every fork on the machine.
        if [ -e "$(git -C "$repo" rev-parse --path-format=absolute --git-path rebase-merge 2>/dev/null)" ] \
        || [ -e "$(git -C "$repo" rev-parse --path-format=absolute --git-path rebase-apply 2>/dev/null)" ]; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$tip" "rebase" - "$cmd"
            continue
        fi
        if ! git -C "$repo" rev-parse --verify --quiet "$tip" >/dev/null 2>&1; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$tip" "-" - "$cmd"
            continue
        fi

        # Offline, or an upstream that has gone away. Neither is worth a warning
        # on a sync that has otherwise succeeded, so the fork is simply skipped
        # and the next run asks again. --no-tags because nothing below reads a
        # tag, and a fork of a busy repo drags hundreds along on every fetch.
        git -C "$repo" fetch --quiet --no-tags upstream 2>/dev/null || continue

        # `upstream/HEAD` is the symref git sets on fetch, and the only thing
        # that knows a project calling its trunk `master`. Resolved through
        # rev-parse rather than symbolic-ref so that a *dangling* one — its
        # branch deleted upstream — falls through to the candidates below
        # instead of naming a ref that no longer exists, which read as "not
        # behind" and dropped the fork from the report in silence.
        ref=""
        for candidate in upstream/HEAD upstream/main upstream/master; do
            if git -C "$repo" rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
                ref="$candidate"
                break
            fi
        done
        [ -n "$ref" ] || continue

        behind=$(git -C "$repo" rev-list --count "$tip..$ref" 2>/dev/null) || continue

        # Is this branch published as it stands? The one question nothing else
        # asks: `t3fork` offers the push and never takes it, so declining leaves
        # the fork unpublished with no trace at all — and since docs/adr/0003 the
        # droplet builds origin, so it keeps serving the previous build while the
        # desktop looks fine. That went unnoticed for a day.
        #
        # A yes/no, deliberately, and not a count. Counting was tried and every
        # bound is an argument: `--cherry-pick` over the whole symmetric
        # difference answers 310 for a fork rebased past 300 upstream commits, of
        # which exactly 3 were patches whose content differed — a number that is
        # literally true and tells the reader nothing. `--is-ancestor` asks the
        # question the reader actually has, in one call, and answers `no` for a
        # branch merely *behind* origin, which no count does.
        #
        # Read off the tracking ref, no fetch: unlike the drift above, this is
        # measured as of the last time anything fetched origin, which the
        # rendered line says out loud. `$tip` of `HEAD` means a detached
        # checkout, where `origin/HEAD` resolves to origin's default branch and
        # the comparison is against a ref nobody here maintains — the same bogus
        # answer the `$tip` default already guards the drift count from.
        local unpushed=-
        if [ "$tip" != HEAD ] \
           && git -C "$repo" rev-parse --verify --quiet "origin/$tip" >/dev/null 2>&1; then
            if git -C "$repo" merge-base --is-ancestor "$tip" "origin/$tip" 2>/dev/null; then
                unpushed=no
            else
                unpushed=yes
            fi
        fi

        # Either question answering yes is worth a row: a fork level with
        # upstream can still be sitting on work nobody else can see.
        [ "$behind" -gt 0 ] || [ "$unpushed" = yes ] || continue

        # Only here is there an upstream ref to name, which is why this is the
        # one row kind that can fall back to a plain rebase.
        printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$tip" "$behind" "$unpushed" \
            "${cmd:-git -C $repo rebase $ref}"
    # `-type d` keeps linked worktrees out: they share the main checkout's
    # remotes, so each would report the same drift again under its own name.
    # `-printf %h` and the sort match backup-projects.sh's walk of the same
    # tree, and make the order stable between runs.
    done < <(find "$root" -maxdepth 3 -name .git -type d -printf '%h\n' 2>/dev/null | sort)
}

# One archive serves every machine, so a backup another machine pushed carries
# secrets this one does not have yet — and until they are restored here, this
# machine cannot back up at all: `dots backup create` refuses while it is
# behind, precisely so a subset never overwrites a superset. Both reasons make
# "there is a newer backup" worth saying during a sync.
#
# Reports only. Restoring drops files into place and re-clones repos; that is
# not something to do to someone in the middle of an unattended update. Paths
# mirror backup-projects.sh, which owns them and cannot be sourced (it runs a
# command on source).
report_backup_available() {
    local dir="$HOME/Backups/projects-backup"
    # No backup repo means the feature is not in use on this machine.
    [ -d "$dir/.git" ] || return 0
    # Offline, or the backup remote is unreachable: silent, like every other
    # network check here. The next run asks again.
    spin_run "Checking for a newer backup..." git -C "$dir" fetch -q origin || return 0
    git -C "$dir" rev-parse --verify --quiet origin/HEAD >/dev/null 2>&1 || return 0

    local behind
    behind=$(git -C "$dir" rev-list --count HEAD..origin/HEAD 2>/dev/null) || return 0
    [ "${behind:-0}" -gt 0 ] || return 0

    local when
    when=$(git -C "$dir" log -1 --format=%ad --date=short origin/HEAD 2>/dev/null)
    print_header "Backup"
    print_warning "$behind newer backup(s) waiting${when:+, latest from $when}"
    print_info "  Another machine backed up after this one. Restoring brings its"
    print_info "  secrets here — and 'dots backup create' stays blocked until you do."

    # Offer it only where there is somebody to answer. Run from a hook, a cron
    # job or a pipe there is no terminal, and a restore is far too consequential
    # to start on a guess — it re-clones repos and writes secrets to disk. So no
    # tty means the command, and nothing else.
    if [ ! -t 0 ] || ! command_exists gum; then
        print_info "  dots backup restore"
        return 0
    fi

    echo ""
    if ! confirm_or_abort "Restore it now?"; then
        print_info "  dots backup restore"
        return 0
    fi

    # Never fatal to the sync: everything above this point has already happened
    # and the anchor is stamped, so a failed restore costs the restore, nothing
    # more. It asks for the age passphrase itself.
    "$DOTFILES_DIR/tools/backup-projects.sh" restore \
        || print_warning "Restore did not complete — run 'dots backup restore' to retry"
}

# Silent when every fork is current: `dots update` should not grow a section
# that exists to say there is nothing to do.
report_fork_drift() {
    local drift
    spin_capture drift "Checking forks against upstream..." fork_drift || return 0
    [ -n "$drift" ] || return 0

    print_header "Forks"
    # The rows carry the repo path, not its name: two of the four kinds need a
    # `git -C` command built for them here, and the name is one expansion away.
    # The four are `rebase`, `-` (no such branch), a non-zero count, and — since
    # the unpushed question joined this walk — a `0` count on a row that exists
    # only because the branch is unpublished.
    local repo branch behind unpushed cmd
    while IFS=$'\t' read -r repo branch behind unpushed cmd; do
        # Unpushed first: it is the one the reader can act on with no thinking,
        # and the one that has a second machine waiting on it.
        #
        # No mention of the droplet, however tempting: this walk reports every
        # fork on the machine and only t3code feeds the host, so the line would
        # be false on all the others. That knowledge stays in `t3fork`, which
        # offers the rebuild, and in docs/adr/0003.
        #
        # "as of the last fetch" is not a hedge: the count is read off the
        # tracking ref without fetching origin, so a branch another machine
        # published minutes ago still reads as unpublished here.
        if [ "$unpushed" = yes ]; then
            print_warning "${repo##*/} ($branch): not on origin as of the last fetch"
        fi
        case "$behind" in
            rebase)
                print_warning "${repo##*/} ($branch): a rebase is in progress — drift not measured"
                print_info "  Its branch still points where it did before, so any count"
                print_info "  here would read as though nothing had been attempted."
                print_info "  git -C $repo rebase --continue    # or --abort to back out"
                ;;
            -)
                print_warning "${repo##*/}: no '$branch' branch in this checkout"
                print_info "  Its patches live there — check 'git remote -v', this is"
                print_info "  what a clone of the wrong fork looks like."
                ;;
            # `[ -gt 0 ]` rather than a `0) ;;` arm: a bare no-op arm is what the
            # next reader deletes as dead code, and deleting it brings back
            # "upstream is 0 commit(s) ahead" on every unpushed-only row.
            *)  [ "$behind" -gt 0 ] \
                    && print_warning "${repo##*/} ($branch): upstream is $behind commit(s) ahead"
                ;;
        esac
        # Named after the way out, not instead of it: finishing a rebase by hand
        # leaves whatever the fork's command also does — a rebuilt AppImage, for
        # t3code — undone, and once the rebase completes the drift is zero and
        # this fork drops out of the report entirely without ever saying so.
        # The fork's own command, but only when it is the fork's own: the
        # fallback below is `git … rebase <upstream>`, which is the way out of
        # being behind and a no-op for being unpublished. Printed under an
        # unpushed-only row it sends the reader to run something that changes
        # nothing, and the warning returns on the next sync.
        if [ "$behind" = 0 ] && [ "${cmd#git }" != "$cmd" ]; then
            # An unpushed-only row whose command is the generic `git … rebase`
            # fallback: that is the way out of being behind and a no-op for being
            # unpublished. The reader runs it, nothing changes, and the warning
            # comes back next sync. A fork with its own `dotfiles.forkUpdate` —
            # t3code's re-offers the push — falls to the branch below instead.
            print_info "  git -C $repo push --force-with-lease origin $branch"
        elif [ -n "$cmd" ]; then
            print_info "  $cmd"
        fi
    done <<<"$drift"
    return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────

do_sync() {
    if ! machine_is_managed; then
        print_error "This machine has not been set up yet"
        print_info "Run 'dots setup' first — there is nothing to bring up to date."
        return 1
    fi

    # No pull here — `dots` runs it as its own process first, see pull_repo.
    resolve_base
    # Before anything installs — see the function.
    update_system_packages
    reconcile_group_flags
    # Before sync_packages, and independent of the anchor — see the function.
    reconcile_custom_requires
    sync_packages
    # After sync_packages: a service is worth offering only once the package that
    # ships its unit is actually on the machine.
    reconcile_declared_services

    print_header "Dotfiles"
    # Not apply_dotfiles: the tool refresh has to land between the apply and the
    # reconciliation, so that waybar restarts after the binaries its modules run.
    chezmoi_apply
    update_tools
    # The file list decides which surfaces need reconciling; an unanchored run
    # passes none, which means "reconcile everything".
    run_post_apply "${CHANGED_FILES[@]}"

    # After the apply, which is what puts wallpaper-picker.sh on the machine that
    # is missing this — the seed inside it runs the picker.
    reconcile_login_wallpaper
    reconcile_encrypted_dns

    # record_synced_state declines on its own while a package shortfall is
    # outstanding — mark_sync_shortfall in common.sh carries the why. Everything
    # above this line has still happened, so the cost is one re-offer next run.
    record_synced_state

    # Before the verdict, which has to be the last thing on screen: a green
    # "Machine in sync" trailed by a yellow fork warning reads as though the
    # sync had left something undone, which is exactly what this is not.
    report_fork_drift
    report_backup_available

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

Brings this machine in line with the dotfiles repo: pulls, upgrades the pacman/AUR
side through cachy-update (or paru where that is absent — accept or refuse it, the
sync continues either way), offers what the repo has gained since the last sync and
what it has dropped, applies the configs, refreshes the tools, reloads the
surfaces that need it, and offers the one privileged step an apply cannot carry —
the wallpaper the lock and login screens share — on a machine missing it. Also
names any fork in the projects tree that upstream has moved past, and any backup
another machine pushed that this one has not restored.

Commands:
  (none)      Run the full sync — assumes 'dots' already ran the pull below
  pull        Only pull the repo. Its own step so the sync always runs on the
              code the pull brought in; 'dots update' does this for you
  tools       Only refresh curl/npm/cargo tools and apps (see 'dots update tools help')
  help        Show this help message
EOF
}

case "${1:-}" in
    ""|sync)        do_sync ;;
    # Its own run, so that the sync below always starts on the code the pull
    # brought in. `dots` calls this first; see pull_repo for why it is separate.
    pull)           pull_repo ;;
    tools)          shift; "$DOTFILES_DIR/tools/manage-updates.sh" "$@" ;;
    help|--help|-h) usage ;;
    *)              usage; exit 1 ;;
esac
