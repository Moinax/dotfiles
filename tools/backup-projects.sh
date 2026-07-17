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
EXTRA_INCLUDES_FILE="$HOME/.config/projects-backup/extra-includes"

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
)

usage() {
    cat <<'EOF'
Usage: backup-projects.sh <command> [options]

Commands:
  create [--dry-run] [--local-only]   Build encrypted backup (and push it)
  restore [archive] [--force]         Re-clone repos and restore secret files
  list [archive]                      Show contents of a backup archive
  help                                Show this help message

create:
  --dry-run      Show what would be backed up, don't write anything
  --local-only   Write the archive to ~/Backups but skip the GitHub repo

restore:
  archive        Path to a .tar.zst.age file; defaults to the latest one
                 pulled from the private GitHub backup repo
  --force        Overwrite existing secret files (default: skip them)

Extra per-repo files can be added as regex lines (matched against paths
relative to ~/Projects) in ~/.config/projects-backup/extra-includes.
EOF
}

require_tools() {
    local missing=()
    for tool in "$@"; do
        command_exists "$tool" || missing+=("$tool")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing[*]}"
        print_info "Install with: sudo pacman -S ${missing[*]}"
        return 1
    fi
}

# ── Scanning ─────────────────────────────────────────────────────────────────

find_repos() {
    find "$PROJECTS_DIR" -maxdepth 3 -name .git -type d -printf '%h\n' 2>/dev/null | sort
}

# Untracked + ignored files in a repo that match the include patterns.
repo_secret_files() {
    local repo="$1"
    local pattern extra
    pattern=$(IFS='|'; echo "${INCLUDE_PATTERNS[*]}")
    if [ -f "$EXTRA_INCLUDES_FILE" ]; then
        while IFS= read -r extra; do
            [ -n "$extra" ] && [[ "$extra" != \#* ]] && pattern+="|$extra"
        done < "$EXTRA_INCLUDES_FILE"
    fi
    {
        git -C "$repo" ls-files --others --ignored --exclude-standard
        git -C "$repo" ls-files --others --exclude-standard
    } 2>/dev/null | grep -vE "$EXCLUDE_DIRS_RE" | grep -E "$pattern" | sort -u || true
}

# Warn about work that a manifest-based backup cannot save.
check_repo_safety() {
    local repo="$1" rel="$2"
    if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        print_warning "$rel has uncommitted changes (not part of the backup)"
    fi
    if [ -n "$(git -C "$repo" log --branches --not --remotes --oneline 2>/dev/null | head -1)" ]; then
        print_warning "$rel has unpushed commits (not part of the backup)"
    fi
}

# ── Create ───────────────────────────────────────────────────────────────────

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

    local stage
    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' EXIT
    mkdir -p "$stage/manifest" "$stage/projects" "$stage/home"

    print_header "Backing up ~/Projects"

    # Manifest: one line per repo (path, remote, branch) so restore can
    # re-clone everything into place.
    local repo rel remote branch file_count=0 repo_count=0
    while IFS= read -r repo; do
        rel="${repo#"$PROJECTS_DIR"/}"
        remote=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
        branch=$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || true)
        if [ -z "$remote" ]; then
            print_warning "$rel has no origin remote — its code is NOT backed up"
        fi
        printf '%s\t%s\t%s\n' "$rel" "$remote" "$branch" >> "$stage/manifest/repos.tsv"
        repo_count=$((repo_count + 1))

        check_repo_safety "$repo" "$rel"

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

    # Home files
    local item
    for item in "${HOME_INCLUDES[@]}"; do
        [ -e "$HOME/$item" ] || continue
        echo "  ~/$item"
        if ! $dry_run; then
            mkdir -p "$stage/home/$(dirname "$item")"
            cp -a "$HOME/$item" "$stage/home/$(dirname "$item")/"
        fi
    done

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
            gum confirm "Create private GitHub repo $slug for backups?" || {
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
    git -C "$BACKUP_REPO_DIR" add "$ARCHIVE_NAME"
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
            print_info "Run './manage.sh backup create' first, or pass an archive path" >&2
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

do_restore() {
    local archive="" force=false
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            -*) print_error "Unknown option: $arg"; return 1 ;;
            *) archive="$arg" ;;
        esac
    done

    require_tools git tar zstd age
    archive=$(resolve_archive "$archive") || return 1

    local stage
    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' EXIT
    decrypt_to "$archive" "$stage"

    print_header "Restoring ~/Projects"

    # Re-clone every repo from the manifest, then check out its branch.
    local rel remote branch dest
    while IFS=$'\t' read -r rel remote branch; do
        dest="$PROJECTS_DIR/$rel"
        if [ -d "$dest" ]; then
            print_info "$rel already exists, not cloning"
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
        else
            print_error "Failed to clone $remote"
        fi
    done < "$stage/manifest/repos.tsv"

    # Drop secret files back into repos and $HOME. Existing files are kept
    # unless --force, so a restore never silently clobbers newer local state.
    restore_tree "$stage/projects" "$PROJECTS_DIR" "$force"
    restore_tree "$stage/home" "$HOME" "$force"

    # tar as non-root applies the umask, so re-tighten ssh perms explicitly.
    if [ -d "$HOME/.ssh" ]; then
        chmod 700 "$HOME/.ssh"
        find "$HOME/.ssh" -type f ! -name '*.pub' -exec chmod 600 {} +
    fi

    print_success "Restore complete"
    print_info "Repos are fresh clones — reinstall dependencies per project (npm install, uv sync, ...)"
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

case "${1:-}" in
    create)  shift; do_create "$@" ;;
    restore) shift; do_restore "$@" ;;
    list)    shift; do_list "$@" ;;
    help|--help|-h) usage ;;
    "")      do_menu ;;
    *)       print_error "Unknown command: $1"; usage; exit 1 ;;
esac
