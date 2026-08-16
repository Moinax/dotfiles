#!/bin/bash
# Backup and restore ~/Projects secrets + repo manifest.
#
# The repos themselves live on GitHub, so the backup only captures what a
# fresh clone can't recreate: gitignored env/config files, a manifest of
# every repo (remote + branch) to re-clone from, and a few secret-bearing
# home files (~/.npmrc, ~/.ssh, ~/.config/gh). The result is a single
# age-encrypted archive small enough to store anywhere — by default it is
# committed to a private GitHub repo so history doubles as versioning.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../install/lib/common.sh"

install_interrupt_trap

PROJECTS_DIR="$HOME/Projects"
BACKUP_REPO_NAME="projects-backup"
BACKUP_REPO_DIR="$HOME/Backups/$BACKUP_REPO_NAME"
ARCHIVE_NAME="projects-backup.tar.zst.age"

# User-extensible config: one entry per line, # comments allowed. The in-script
# arrays/regexes below are the defaults; these files extend them without
# editing the versioned script.
CONFIG_DIR="$HOME/.config/projects-backup"
EXTRA_INCLUDES_FILE="$CONFIG_DIR/extra-includes"           # repo-relative path regexes
EXTRA_HOME_INCLUDES_FILE="$CONFIG_DIR/extra-home-includes" # paths relative to ~
EXTRA_EXCLUDE_DIRS_FILE="$CONFIG_DIR/extra-exclude-dirs"   # directory-name regexes

# Gitignored/untracked files worth backing up, matched against repo-relative
# paths. Anything not matched is assumed regenerable (node_modules, caches…).
INCLUDE_PATTERNS=(
    '(^|/)\.env(\..+)?$'
    '(^|/)\.envrc$'
    '(^|/)\.npmrc$'
    '(^|/)docker-compose\.override\.ya?ml$'
    '(^|/)\.claude/settings\.local\.json$'
    '(^|/)(secrets?|credentials)(\.[^/]+)?$'
)

# Directories whose contents are never worth backing up, even when a file
# inside happens to match an include pattern (vendored deps ship files named
# .env, credentials.py, ...).
EXCLUDE_DIRS_RE='(^|/)(node_modules|\.venv|venv|\.git|dist|build|target|coverage|vendor|__pycache__|\.(next|nuxt|turbo|cache|pytest_cache|ruff_cache|yarn|pnpm-store|gradle|terraform))(/|$)'

# Secret-bearing files outside ~/Projects, relative to $HOME.
HOME_INCLUDES=(
    .npmrc
    .ssh
    .config/gh
    .config/projects-backup
    # tea (Gitea CLI) logins: API tokens, so they can't live in the public
    # dotfiles repo. config.yml only — never the sibling config.yml.lock.
    .config/tea/config.yml
)

usage() {
    cat <<'EOF'
Usage: backup-projects.sh <command> [options]

Commands:
  create [--dry-run] [--local-only]   Build encrypted backup (and push it)
  restore [archive] [--force] [--home-only]
                                      Re-clone repos and restore secret files
  list [archive]                      Show contents of a backup archive
  help                                Show this help message

create:
  --dry-run      Show what would be backed up, don't write anything
  --local-only   Write the archive to ~/Backups but skip the GitHub repo

restore:
  archive        Path to a .tar.zst.age file; defaults to the latest one
                 pulled from the private GitHub backup repo
  --force        Overwrite existing secret files (default: skip them)
  --home-only    Only restore home secrets (~/.ssh, ~/.npmrc, ~/.config/gh, ...);
                 skip re-cloning ~/Projects repos
  --no-home      The inverse: repos and their secrets, but no home secrets.
                 What you want on a machine that must not hold your keyring
  --only a,b     Restore only these top-level ~/Projects directories
  --exclude a,b  Restore everything except these ones

A scoped restore describes part of the machine, so it never offers to trash the
repos it left out.

Config files in ~/.config/projects-backup/ (one entry per line, # comments):
  extra-includes       extra path regexes to back up (repo-relative paths)
  extra-home-includes  extra files/dirs to back up (relative to ~)
  extra-exclude-dirs   extra directory names to skip while scanning repos

What is NOT backed up: repo contents. Restore re-clones from each repo's origin,
so anything that never left the machine is lost — unpushed commits, local-only
branches, stashes, submodules, worktrees, hooks. Push before you rely on this.
EOF
}

# ── Scanning ─────────────────────────────────────────────────────────────────

find_repos() {
    find "$PROJECTS_DIR" -maxdepth 3 -name .git -type d -printf '%h\n' 2>/dev/null | sort
}

# Read non-comment, non-empty lines from a config file (missing file → nothing).
read_config_lines() {
    [ -f "$1" ] || return 0
    grep -vE '^[[:space:]]*(#|$)' "$1" || true
}

# Combined include/exclude regexes (in-script defaults + config-file extras),
# built once on first use — they are constant for the whole run.
INCLUDE_RE=""
EXCLUDE_RE=""
build_filter_res() {
    local extra
    INCLUDE_RE=$(IFS='|'; echo "${INCLUDE_PATTERNS[*]}")
    while IFS= read -r extra; do
        INCLUDE_RE+="|$extra"
    done < <(read_config_lines "$EXTRA_INCLUDES_FILE")

    EXCLUDE_RE="$EXCLUDE_DIRS_RE"
    while IFS= read -r extra; do
        EXCLUDE_RE+="|(^|/)(${extra})(/|\$)"
    done < <(read_config_lines "$EXTRA_EXCLUDE_DIRS_FILE")
}

# Untracked + ignored files in a repo that match the include patterns.
repo_secret_files() {
    local repo="$1"
    [ -n "$INCLUDE_RE" ] || build_filter_res
    # --others with no exclude flags lists every untracked file, ignored or not.
    git -C "$repo" ls-files --others 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" | grep -E "$INCLUDE_RE" | sort || true
}

# ── Create ───────────────────────────────────────────────────────────────────

# One archive serves every machine, so a backup is only ever allowed to move
# forward. A machine that is behind holds none of what the newer archive added:
# backing up from it would replace a superset with a subset, and since the file
# has a single name the loss is invisible — the push succeeds, HEAD looks fine,
# and the secrets another machine contributed are only in history.
#
# So refuse, and send the user through `restore` first. That is not a detour: a
# restore brings the missing repos and secret files onto this machine, after
# which its own backup genuinely contains everything. Restore-then-backup is
# what makes the archive cumulative rather than last-writer-wins.
#
# Refusing is also the behaviour this replaced, by accident: before the archive
# name became shared, a diverged push was simply rejected by git. That rejection
# was doing real work.
backup_repo_is_current() {
    [ -d "$BACKUP_REPO_DIR/.git" ] || return 0

    if ! git -C "$BACKUP_REPO_DIR" fetch -q origin 2>/dev/null; then
        # Offline is not a reason to block a local backup — nothing can be
        # overwritten while nothing can be pushed.
        print_warning "Could not reach the backup repo — backing up without checking it"
        return 0
    fi
    git -C "$BACKUP_REPO_DIR" rev-parse --verify --quiet origin/HEAD >/dev/null 2>&1 || return 0

    local behind
    behind=$(git -C "$BACKUP_REPO_DIR" rev-list --count HEAD..origin/HEAD 2>/dev/null) || return 0
    [ "${behind:-0}" -gt 0 ] || return 0

    print_error "The backup repo has $behind newer backup(s) this machine does not have"
    print_info "Another machine backed up after this one last synced. Backing up now would"
    print_info "replace that archive with this machine's, dropping whatever only it holds."
    echo ""
    print_info "Restore first, then back up:"
    print_info "  dots backup restore"
    print_info "  dots backup create"
    echo ""
    print_info "To write a local archive without touching the shared one:"
    print_info "  dots backup create --local-only"
    return 1
}

do_create() {
    local dry_run=false local_only=false
    for arg in "$@"; do
        case "$arg" in
            --dry-run)    dry_run=true ;;
            --local-only) local_only=true ;;
            *) print_error "Unknown option: $arg"; return 1 ;;
        esac
    done

    require_tools git tar zstd
    $dry_run || require_tools age

    # Refused before any work is done: scanning, compressing and asking for a
    # passphrase only to stop at the push wastes the one step that needs you.
    if ! $dry_run && ! $local_only; then
        backup_repo_is_current || return 1
    fi

    local stage
    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' EXIT
    mkdir -p "$stage/manifest" "$stage/projects" "$stage/home"

    print_header "Backing up ~/Projects"

    # Manifest: one line per repo (path, remote, branch) so restore can
    # re-clone everything into place. Anything else goes in a sidecar file
    # rather than a fourth column, so an older restore ignores what it does not
    # know instead of folding it into `branch`.
    local repo rel remote branch name url file_count=0 repo_count=0
    while IFS= read -r repo; do
        rel="${repo#"$PROJECTS_DIR"/}"
        remote=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
        branch=$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || true)
        if [ -z "$remote" ]; then
            print_warning "$rel has no origin remote — its code is NOT backed up"
        fi
        printf '%s\t%s\t%s\n' "$rel" "$remote" "$branch" >> "$stage/manifest/repos.tsv"
        repo_count=$((repo_count + 1))

        # Secondary remotes. A clone restores origin and nothing else, so
        # without this a fork comes back with no `upstream` — and since "no
        # upstream remote" is indistinguishable from "not a fork", every tool
        # that keys off it (dots update's fork check) goes quiet rather than
        # complaining.
        #
        # Read through `config` rather than `remote get-url`: that one echoes
        # the remote's own *name* and exits 0 when a remote has no url, so the
        # `|| continue` never fires and a junk row goes to the manifest. It also
        # applies `insteadOf` rewrites, and the rewritten URL is the wrong thing
        # to archive — the restored machine has the same rules and would apply
        # them again.
        while IFS= read -r name; do
            [ "$name" = origin ] && continue
            url=$(git -C "$repo" config --get "remote.$name.url") || continue
            printf '%s\t%s\t%s\n' "$rel" "$name" "$url" >> "$stage/manifest/remotes.tsv"
        done < <(git -C "$repo" remote 2>/dev/null || true)

        local f
        while IFS= read -r f; do
            [ -f "$repo/$f" ] || continue
            echo "  $rel/$f"
            if ! $dry_run; then
                mkdir -p "$stage/projects/$rel/$(dirname "$f")"
                cp -p "$repo/$f" "$stage/projects/$rel/$f"
            fi
            file_count=$((file_count + 1))
        done < <(repo_secret_files "$repo")
    done < <(find_repos)

    # Home files (defaults + extra-home-includes config lines)
    local item
    while IFS= read -r item; do
        [ -e "$HOME/$item" ] || continue
        echo "  ~/$item"
        if ! $dry_run; then
            mkdir -p "$stage/home/$(dirname "$item")"
            cp -a "$HOME/$item" "$stage/home/$(dirname "$item")/"
        fi
    done < <(printf '%s\n' "${HOME_INCLUDES[@]}"; read_config_lines "$EXTRA_HOME_INCLUDES_FILE")

    print_info "$repo_count repos in manifest, $file_count secret files collected"

    if $dry_run; then
        print_success "Dry run complete — nothing written"
        return 0
    fi

    printf 'date\t%s\nhost\t%s\n' "$(date +%F_%H-%M)" "$(uname -n)" > "$stage/manifest/meta.tsv"

    mkdir -p "$HOME/Backups"
    local out="$HOME/Backups/$ARCHIVE_NAME"
    print_info "Encrypting archive (age will ask for a passphrase)..."
    tar -C "$stage" --zstd -cf "$stage/archive.tar.zst" manifest projects home
    age -p -o "$out" "$stage/archive.tar.zst"
    print_success "Backup written to $out ($(du -h "$out" | cut -f1))"

    $local_only && return 0
    push_to_backup_repo "$out"
}

push_to_backup_repo() {
    local archive="$1"
    require_tools gh

    if [ ! -d "$BACKUP_REPO_DIR/.git" ]; then
        local user slug
        user=$(gh api user -q .login) || {
            print_error "gh is not authenticated; run 'gh auth login' or use --local-only"
            return 1
        }
        slug="$user/$BACKUP_REPO_NAME"
        if ! gh repo view "$slug" &>/dev/null; then
            confirm_or_abort "Create private GitHub repo $slug for backups?" || {
                print_info "Skipped push — archive kept at $archive"
                return 0
            }
            gh repo create "$slug" --private
            print_success "Created private repo $slug"
        fi
        # -q: a fresh backup repo is empty and git's warning about it is noise
        gh repo clone "$slug" "$BACKUP_REPO_DIR" -- -q 2>/dev/null
    fi

    cp "$archive" "$BACKUP_REPO_DIR/$ARCHIVE_NAME"
    # -A, not just $ARCHIVE_NAME: this repo is now the home of a second archive
    # too. `dots droplet snapshot` writes the host's credentials here precisely
    # so they ride off-site with this one, and staging only our own filename left
    # that file untracked forever — the ride-along it was placed here for never
    # happened. Nothing else is ever written into this directory.
    git -C "$BACKUP_REPO_DIR" add -A
    if git -C "$BACKUP_REPO_DIR" diff --cached --quiet; then
        print_info "Backup unchanged since last push"
        return 0
    fi
    git -C "$BACKUP_REPO_DIR" commit -q -m "backup $(date +%F_%H-%M)"
    # -u origin HEAD so the very first push into a fresh empty repo works too
    git -C "$BACKUP_REPO_DIR" push -qu origin HEAD
    print_success "Backup pushed to GitHub ($BACKUP_REPO_NAME)"
}

# ── Restore ──────────────────────────────────────────────────────────────────

# Resolve the archive to restore from: explicit path, or pull the latest
# from the private GitHub backup repo.
resolve_archive() {
    # Runs inside $(...) — anything for the user must go to stderr, only the
    # resolved path may hit stdout.
    local archive="$1"
    if [ -n "$archive" ]; then
        [ -f "$archive" ] || { print_error "Archive not found: $archive" >&2; return 1; }
        echo "$archive"
        return 0
    fi
    require_tools gh >&2
    if [ -d "$BACKUP_REPO_DIR/.git" ]; then
        git -C "$BACKUP_REPO_DIR" pull -q
    else
        local user
        user=$(gh api user -q .login) || {
            print_error "gh is not authenticated and no archive path was given" >&2
            return 1
        }
        if ! gh repo view "$user/$BACKUP_REPO_NAME" &>/dev/null; then
            print_error "No backup repo on GitHub ($user/$BACKUP_REPO_NAME)" >&2
            print_info "Run 'dots backup create' first, or pass an archive path" >&2
            return 1
        fi
        gh repo clone "$user/$BACKUP_REPO_NAME" "$BACKUP_REPO_DIR" -- -q 2>/dev/null
    fi
    [ -f "$BACKUP_REPO_DIR/$ARCHIVE_NAME" ] || {
        print_error "No $ARCHIVE_NAME in $BACKUP_REPO_DIR" >&2
        return 1
    }
    echo "$BACKUP_REPO_DIR/$ARCHIVE_NAME"
}

decrypt_to() {
    local archive="$1" stage="$2"
    print_info "Decrypting $archive..."
    age -d -o "$stage/archive.tar.zst" "$archive"
    tar -C "$stage" --zstd -xf "$stage/archive.tar.zst"
}

# Put back the remotes a clone does not carry. Strictly additive: `remote add`
# on a name that already exists fails and changes nothing, so this is safe to
# run over a checkout that is already on disk — which is the point, since a
# machine restored before this existed has repos sitting there with no
# `upstream` and needs a way to get them back.
#
# read_config_lines gives the "missing file → nothing" contract for free, so an
# archive written before this manifest existed restores unchanged.
restore_repo_extras() {
    local stage="$1" rel="$2" dest="$3"
    local row_rel name url

    while IFS=$'\t' read -r row_rel name url; do
        [ "$row_rel" = "$rel" ] || continue
        git -C "$dest" remote add "$name" "$url" 2>/dev/null || true
    done < <(read_config_lines "$stage/manifest/remotes.tsv")
}

# Which top-level ~/Projects directory a manifest path belongs to. Scoping is
# deliberately one level deep: it is the level the directories mean something at
# (labs, o27, mbrella), and a deeper spec would just be a repo list.
scope_of() { printf '%s\n' "${1%%/*}"; }

# Comma-list membership, without splitting: the commas that fence the needle are
# what stop `o2` matching `o27`. An empty list matches nothing, which is what
# makes "no opinion" work — an unset --only lets everything through, an unset
# --exclude rejects nothing.
scope_in_list() {
    case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

# Drop everything outside the scope from the decrypted stage, so the manifest
# loop, restore_tree and the unlisted-repo check all agree without each
# re-deriving the filter. Exactly one of $only / $exclude is non-empty.
prune_stage_to_scope() {
    local stage="$1" only="$2" exclude="$3"
    local row scope dir kept="$stage/manifest/repos.kept"

    # The --only/--exclude polarity, said once. Written per loop it was the same
    # four lines twice, and the second copy is the one where getting it backwards
    # deletes staged secrets instead of skipping a manifest row.
    in_scope() {
        if [ -n "$only" ]; then scope_in_list "$1" "$only"
        else                  ! scope_in_list "$1" "$exclude"; fi
    }

    # Rows pass through whole: nothing here reads a column, and reassembling one
    # with printf is the only thing that could ever change a manifest's bytes.
    # The scope still comes from the first FIELD, not the row — cut the row at
    # its first `/` and a repo sitting directly in ~/Projects yields
    # "name<TAB>https:", because the first slash it has is the remote's.
    : > "$kept"
    while IFS= read -r row; do
        scope=${row%%$'\t'*}
        in_scope "$(scope_of "$scope")" && printf '%s\n' "$row" >> "$kept"
    done < "$stage/manifest/repos.tsv"
    mv "$kept" "$stage/manifest/repos.tsv"

    [ -d "$stage/projects" ] || return 0
    while IFS= read -r dir; do
        scope=${dir##*/}
        in_scope "$scope" || rm -rf "$dir"
    done < <(find "$stage/projects" -mindepth 1 -maxdepth 1 -type d)

    # Not decorative: the loop's status is the last scope test, so a final
    # "kept" directory makes this function return 1 and `set -e` aborts the
    # restore halfway through the prune.
    return 0
}

do_restore() {
    local archive="" force=false home_only=false no_home=false only="" exclude=""
    local scope_given=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=true ;;
            --home-only) home_only=true ;;
            --no-home) no_home=true ;;
            --only) shift; only="${1:-}"; scope_given=true ;;
            --only=*) only="${1#*=}"; scope_given=true ;;
            --exclude) shift; exclude="${1:-}"; scope_given=true ;;
            --exclude=*) exclude="${1#*=}"; scope_given=true ;;
            -*) print_error "Unknown option: $1"; return 1 ;;
            *) archive="$1" ;;
        esac
        # `|| break`, not a bare shift: the two value-consuming branches may have
        # emptied $@ already, and a failing `shift` under `set -e` ends the whole
        # process with nothing printed.
        shift || break
    done

    # A scope flag whose value went missing must not fall through as "no scope":
    # that restores everything and re-arms the offer to trash every repo the
    # scope was meant to leave out — the exact inversion this feature prevents.
    if $scope_given && [ -z "$only$exclude" ]; then
        print_error "--only/--exclude need a comma-separated list of top-level ~/Projects directories"
        return 1
    fi
    if $home_only && $no_home; then
        print_error "--home-only and --no-home ask for opposite things"
        return 1
    fi
    if [ -n "$only" ] && [ -n "$exclude" ]; then
        print_error "Use --only or --exclude, not both"
        return 1
    fi
    if $home_only && { [ -n "$only" ] || [ -n "$exclude" ]; }; then
        print_error "--home-only restores no repos, so scoping them means nothing"
        return 1
    fi

    require_tools git tar zstd age
    archive=$(resolve_archive "$archive") || return 1

    local stage
    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' EXIT
    decrypt_to "$archive" "$stage"

    # Filter once, on the staged copy, rather than at each of the three places
    # that read it (the manifest loop, restore_tree, the unlisted-repo check).
    # Whatever is pruned here is simply not in the backup as far as the rest of
    # this function is concerned.
    local scoped=false
    if [ -n "$only" ] || [ -n "$exclude" ]; then
        scoped=true
        prune_stage_to_scope "$stage" "$only" "$exclude"
        print_info "Scoped restore: $(wc -l < "$stage/manifest/repos.tsv") repos in the manifest"
    fi

    # --no-home is the inverse of --home-only, and the reason it exists: a
    # remote host needs the project secrets without inheriting ~/.ssh, which the
    # backup carries whole. Dropping the staged copy is enough — restore_tree
    # returns early on a missing directory.
    # ${stage:?} rather than $stage: an empty one would make this `rm -rf /home`.
    $no_home && rm -rf "${stage:?}/home"

    if $home_only; then
        print_header "Restoring home secrets"
    else
        print_header "Restoring ~/Projects"
    fi

    # Home secrets go first: the manifest remotes are usually SSH URLs, so the
    # restored ~/.ssh (key + known_hosts) must be in place before any clone.
    restore_tree "$stage/home" "$HOME" "$force"

    # tar as non-root applies the umask, so re-tighten ssh perms explicitly.
    if [ -d "$HOME/.ssh" ]; then
        chmod 700 "$HOME/.ssh"
        find "$HOME/.ssh" -type f ! -name '*.pub' -exec chmod 600 {} +
    fi

    if $home_only; then
        print_success "Home secrets restored"
        print_info "Run 'dots backup restore' later to re-clone ~/Projects"
        return 0
    fi

    # Load the key into the agent once, so a passphrase-protected key doesn't
    # prompt on every clone below. No agent or no key → ssh prompts per clone.
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -f "$HOME/.ssh/id_ed25519" ]; then
        ssh-add -q "$HOME/.ssh/id_ed25519" 2>/dev/null || true
    fi

    # Re-clone every repo from the manifest, then check out its branch.
    local rel remote branch dest
    while IFS=$'\t' read -r rel remote branch; do
        dest="$PROJECTS_DIR/$rel"
        if [ -d "$dest" ]; then
            print_info "$rel already exists, not cloning"
            # Still worth a pass: adding a missing remote cannot clobber
            # anything, and a repo that is on disk but has lost its `upstream`
            # is exactly what this repairs. Restoring from scratch is not the
            # only way to end up needing it.
            restore_repo_extras "$stage" "$rel" "$dest"
            continue
        fi
        if [ -z "$remote" ]; then
            print_warning "$rel had no remote — cannot re-clone"
            continue
        fi
        print_info "Cloning $rel..."
        # </dev/null so a git/ssh prompt can't swallow the manifest on stdin
        if git clone -q "$remote" "$dest" < /dev/null; then
            [ -n "$branch" ] && git -C "$dest" checkout -q "$branch" 2>/dev/null || true
            restore_repo_extras "$stage" "$rel" "$dest"
        else
            print_error "Failed to clone $remote"
        fi
    done < "$stage/manifest/repos.tsv"

    # Drop secret files back into the freshly cloned repos. Existing files are
    # kept unless --force, so a restore never silently clobbers newer state.
    restore_tree "$stage/projects" "$PROJECTS_DIR" "$force"

    # A scoped manifest no longer describes the whole machine, so every repo
    # outside the scope would look "absent from the backup" and be offered for
    # the trash. Exactly backwards.
    $scoped || offer_remove_unlisted_repos "$stage/manifest/repos.tsv"

    print_success "Restore complete"
    print_info "Repos are fresh clones — reinstall dependencies per project (npm install, uv sync, ...)"
}

offer_remove_unlisted_repos() {
    local manifest="$1" rel repo removed=0
    local -A listed=()
    local -a unlisted=()

    while IFS=$'\t' read -r rel _; do
        [ -n "$rel" ] && listed["$rel"]=1
    done < "$manifest"

    while IFS= read -r repo; do
        rel="${repo#"$PROJECTS_DIR"/}"
        [ -n "${listed[$rel]+x}" ] || unlisted+=("$repo")
    done < <(find_repos)

    [ ${#unlisted[@]} -gt 0 ] || return 0

    print_warning "Repositories present locally but absent from the backup:"
    printf '  %s\n' "${unlisted[@]#"$PROJECTS_DIR"/}"

    if [ ! -t 0 ]; then
        print_info "Non-interactive restore — keeping these repositories"
        return 0
    fi
    if ! command_exists gio; then
        print_warning "gio is not available — keeping these repositories"
        return 0
    fi

    if command_exists gum; then
        confirm_or_abort "Move these repositories to the trash?" || return 0
    else
        local reply
        read -r -p "Move these repositories to the trash? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || return 0
    fi

    for repo in "${unlisted[@]}"; do
        if gio trash -- "$repo"; then
            removed=$((removed + 1))
        else
            print_error "Could not move ${repo#"$PROJECTS_DIR"/} to the trash"
        fi
    done
    print_info "$removed repositories moved to the trash"
}

restore_tree() {
    local src="$1" dest_root="$2" force="$3"
    [ -d "$src" ] || return 0
    local f dest restored=0 skipped=0
    while IFS= read -r f; do
        dest="$dest_root/${f#./}"
        if [ -e "$dest" ] && [ "$force" != "true" ]; then
            skipped=$((skipped + 1))
            continue
        fi
        mkdir -p "$(dirname "$dest")"
        cp -p "$src/${f#./}" "$dest"
        restored=$((restored + 1))
    done < <(cd "$src" && find . -type f)
    print_info "$(basename "$src"): $restored files restored, $skipped kept (use --force to overwrite)"
}

do_list() {
    require_tools tar zstd age
    local archive
    archive=$(resolve_archive "${1:-}") || return 1
    local stage
    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' EXIT
    decrypt_to "$archive" "$stage"
    echo ""
    cat "$stage/manifest/meta.tsv" 2>/dev/null || true
    echo ""
    print_info "Repos in manifest:"
    cut -f1 "$stage/manifest/repos.tsv" | sed 's/^/  /'
    print_info "Files:"
    (cd "$stage" && find projects home -type f | sed 's/^/  /')
}

# ── Interactive menu ─────────────────────────────────────────────────────────

do_menu() {
    require_tools gum
    local choice
    choice=$(printf '%s\n' "Create backup" "Restore backup" "List backup contents" | \
        gum choose --cursor.foreground="212" --header "Projects backup:") || return 0
    case "$choice" in
        "Create backup")        do_create || true ;;
        "Restore backup")       do_restore || true ;;
        "List backup contents") do_list || true ;;
    esac
    # Pause even after a failure — error output is exactly what the user
    # needs to read before the manager menu redraws over it.
    pause_for_user
}

# Sourced (by tests/test_backup_scope.sh) rather than run: define the functions
# and stop, instead of falling into the menu with no arguments.
(return 0 2>/dev/null) && return 0

case "${1:-}" in
    create)  shift; do_create "$@" ;;
    restore) shift; do_restore "$@" ;;
    list)    shift; do_list "$@" ;;
    help|--help|-h) usage ;;
    "")      do_menu ;;
    *)       print_error "Unknown command: $1"; usage; exit 1 ;;
esac
