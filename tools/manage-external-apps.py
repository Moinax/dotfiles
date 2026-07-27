#!/usr/bin/env python3
"""External Apps Manager — AppImages, Distrobox apps, GitHub release tracking.

Python port of the former tools/manage-external-apps.sh. State files under
~/.local/state/dotfiles/external-apps/ are bash-quoted KEY=VALUE lines
(written with %q by the shell version); shlex reads and writes that format,
so existing state keeps working unchanged.

Interactive UI uses gum when available, with plain-stdin fallbacks.
"""

import fnmatch
import functools
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

XDG_DATA = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
XDG_STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
APPIMAGE_DIR = XDG_DATA / "AppImages"
APP_DESKTOP_DIR = XDG_DATA / "applications"
APP_ICON_DIR = XDG_DATA / "icons"
STATE_DIR = XDG_STATE / "dotfiles" / "external-apps"
DISTROBOX_STATE_DIR = STATE_DIR / "distrobox"
SOURCES_STATE_DIR = STATE_DIR / "sources"

USAGE = """\
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
                 [--container NAME] [--app DESKTOP_ID] [--args "FLAGS"] [--prerelease]
                 [--non-interactive]
      Download the latest GitHub release asset and install it (AppImage → launcher
      import, deb/rpm/pkg.tar → Distrobox install). The source is remembered so the
      app can be kept current with 'check-updates' / 'update'.
      --prerelease follows the newest release including nightlies/betas instead of
      the latest stable one.

  set-source --name APP [--repo <owner/repo | github URL>] [--asset GLOB] [--version TAG]
             [--prerelease | --stable]
      Attach a GitHub release source to an already-installed app. Without --version
      the app reports as updatable until the first 'update' runs.
      Every option but --name is inherited from the saved source when omitted, so
      switching an already-tracked app between channels is just:
        set-source --name APP --prerelease     # follow nightlies/betas
        set-source --name APP --stable         # back to stable releases

  check-updates [--porcelain]
      Compare each app's installed version against its latest GitHub release.
      --porcelain prints outdated apps as "name|installed|latest" lines, apps whose
      check failed as "FAIL|name|repo", and an exhausted API quota as "#ratelimit|<epoch>".

  update [--name APP | --all]
      Re-download the latest release asset and reinstall. AppImages are re-imported
      in place; Distrobox apps are reinstalled in their container with saved launch
      args preserved.

  list
      List all managed apps (AppImages and Distrobox apps). Apps following the
      pre-release channel are marked 'channel=pre-release'.

  latest-release <owner/repo> [owner/repo ...]
      Print "repo<TAB>latest-tag" for each repo, fetched concurrently through one
      shared cache. Used by './manage.sh update' to resolve upstream versions of
      tools that aren't apps; an unresolvable repo yields an empty tag.

Run without arguments for an interactive wizard:
  - Install app (local file): fuzzy-find a file (.AppImage, .deb, .rpm) and auto-detect the install method
  - Install from GitHub release: paste a repo/URL, pick the asset, install + track updates
  - Manage installed apps: update (from GitHub or a local file), switch release channel, or uninstall
  - Check for updates: check all tracked apps and pick which to update
"""

# ── Output helpers ───────────────────────────────────────────────────────────

RED, GREEN, YELLOW, BLUE = "\033[0;31m", "\033[0;32m", "\033[1;33m", "\033[0;34m"
NC = "\033[0m"


def print_info(msg, file=sys.stdout):
    print(f"{BLUE}[INFO]{NC} {msg}", file=file)


def print_success(msg, file=sys.stdout):
    print(f"{GREEN}[SUCCESS]{NC} {msg}", file=file)


def print_warning(msg, file=sys.stdout):
    print(f"{YELLOW}[WARNING]{NC} {msg}", file=file)


def print_error(msg, file=sys.stdout):
    print(f"{RED}[ERROR]{NC} {msg}", file=file)


class AppError(Exception):
    """Fatal command error; the message is printed once and the command exits 1.

    Sites that already printed a rich multi-line error raise AppError("") —
    handlers only print non-empty messages, so nothing shows twice.
    """


class Cancelled(Exception):
    """User cancelled an interactive prompt; flows unwind quietly."""


class Spinner:
    """Terminal spinner on stderr while a blocking operation runs."""

    FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

    def __init__(self, title):
        self.title = title
        self.enabled = sys.stderr.isatty()
        self._stop = threading.Event()
        self._thread = None

    def __enter__(self):
        if self.enabled:
            self._thread = threading.Thread(target=self._run, daemon=True)
            self._thread.start()
        else:
            print_info(self.title, file=sys.stderr)
        return self

    def __exit__(self, *exc):
        if self._thread:
            self._stop.set()
            self._thread.join()
            sys.stderr.write("\r\033[K")
            sys.stderr.flush()
        return False

    def _run(self):
        i = 0
        while not self._stop.wait(0.08):
            frame = self.FRAMES[i % len(self.FRAMES)]
            sys.stderr.write(f"\r\033[K{frame} {self.title}")
            sys.stderr.flush()
            i += 1


# ── gum / prompt helpers ─────────────────────────────────────────────────────


def command_exists(name):
    return shutil.which(name) is not None


def has_gum():
    return command_exists("gum")


def _run_gum(args, options):
    """Run a gum picker over the given options; None means cancelled.

    Only stdout is captured (the selection): gum draws its interactive UI on
    stderr, which must stay connected to the terminal to be visible.
    """
    res = subprocess.run(["gum", *args], input="\n".join(options),
                         stdout=subprocess.PIPE, text=True, check=False)
    if res.returncode != 0:
        return None
    return res.stdout.rstrip("\n")


def gum_choose(options, header="", no_limit=False):
    """Pick from options. Returns a list (no_limit) or a single string; None on cancel."""
    if has_gum():
        args = ["choose", "--cursor.foreground=212"]
        if header:
            args += ["--header", header]
        if no_limit:
            args.append("--no-limit")
        out = _run_gum(args, options)
        if out is None:
            return None
        return [line for line in out.split("\n") if line] if no_limit else out

    if header:
        print(header)
    for i, opt in enumerate(options, 1):
        print(f"  {i}) {opt}")
    try:
        raw = input(f"Choose [1-{len(options)}]: ").strip()
    except EOFError:
        return None
    if raw.isdigit() and 1 <= int(raw) <= len(options):
        picked = options[int(raw) - 1]
        return [picked] if no_limit else picked
    return None


def gum_filter(options, header="", placeholder="Type to search..."):
    if has_gum():
        return _run_gum(["filter", "--header", header, "--placeholder", placeholder], options)
    return gum_choose(options, header=header)


def gum_confirm(prompt, affirmative=None, negative=None):
    if has_gum():
        args = ["gum", "confirm"]
        if affirmative:
            args += ["--affirmative", affirmative]
        if negative:
            args += ["--negative", negative]
        return subprocess.run([*args, prompt], check=False).returncode == 0
    try:
        return input(f"{prompt} [y/N]: ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


def prompt_with_default(header, default_value="", placeholder="", required=True):
    """Prompt for a value; returns the string or raises Cancelled."""
    while True:
        if has_gum():
            # stdout only — gum renders the input UI on stderr (see _run_gum).
            res = subprocess.run(
                ["gum", "input", "--header", header, "--value", default_value,
                 "--placeholder", placeholder],
                stdout=subprocess.PIPE, text=True, check=False)
            if res.returncode != 0:
                raise Cancelled()
            value = res.stdout.rstrip("\n")
        else:
            suffix = f" [{default_value}]" if default_value else ""
            try:
                value = input(f"{header}{suffix}: ")
            except EOFError:
                raise Cancelled()

        value = value.strip()
        if not value and default_value:
            value = default_value
        if value or not required:
            return value
        print_warning("A value is required.", file=sys.stderr)


def confirm_summary(title, lines):
    if has_gum():
        styled = subprocess.run(
            ["gum", "style", "--foreground", "212", "--bold", title],
            capture_output=True, text=True, check=False).stdout.rstrip("\n")
        try:
            with open("/dev/tty", "w") as tty:
                subprocess.run(
                    ["gum", "style", "--border", "rounded", "--border-foreground", "212",
                     "--padding", "1 2", "--margin", "1", styled, "", *lines],
                    stdout=tty, check=False)
        except OSError:
            print(title)
            for line in lines:
                print(line)
        return gum_confirm(f"{title}?", affirmative="Proceed", negative="Cancel")

    print(f"\n{title}\n=========================")
    for line in lines:
        print(line)
    print()
    return gum_confirm("Proceed")


# ── Small utilities ──────────────────────────────────────────────────────────


def slugify(name):
    s = re.sub(r"[^a-z0-9._-]", "-", name.lower())
    s = re.sub(r"-{2,}", "-", s)
    return s.strip("-")


def humanize_appimage_name(name):
    """"T3-Code-0.0.13-x86_64_e879597ed9181500dac6cae7f7d710a7" → "T3 Code"."""
    name = name.removesuffix(".AppImage")
    name = re.sub(r"[_-][0-9a-f]{8,}", "", name)  # hex hashes
    name = re.sub(r"[_-](x86_64|aarch64|arm64|i686|armhf|amd64|x64)", "", name, flags=re.IGNORECASE)
    name = re.sub(r"[_-]v?[0-9]+(\.[0-9]+)*", "", name)  # versions
    name = re.sub(r"[_-]", " ", name)
    return re.sub(r" {2,}", " ", name).strip()


def require_file(path):
    if not Path(path).is_file():
        raise AppError(f"File not found: {path}")


def ensure_dirs():
    for d in (APPIMAGE_DIR, APP_DESKTOP_DIR, APP_ICON_DIR, DISTROBOX_STATE_DIR, SOURCES_STATE_DIR):
        d.mkdir(parents=True, exist_ok=True)


def refresh_desktop_db():
    if command_exists("update-desktop-database"):
        subprocess.run(["update-desktop-database", str(APP_DESKTOP_DIR)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def install_file(src, dest, mode):
    # Copy to a sibling temp file and rename over dest: opening a running
    # AppImage for writing fails with ETXTBSY, while rename swaps the inode
    # and lets the running instance keep executing the old one.
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".tmp")
    try:
        shutil.copyfile(src, tmp)
        tmp.chmod(mode)
        os.replace(tmp, dest)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def default_picker_root():
    downloads = Path.home() / "Downloads"
    return downloads if downloads.is_dir() else Path.home()


def matches_mode(name_lower, mode):
    if mode == "appimage":
        return name_lower.endswith(".appimage")
    if mode == "package":
        return (name_lower.endswith((".deb", ".rpm", ".pkg.tar"))
                or ".pkg.tar." in name_lower)
    if mode == "all":
        return matches_mode(name_lower, "appimage") or matches_mode(name_lower, "package")
    return True


def pick_file_from_downloads(header, mode):
    """Fuzzy-pick an installable file under ~/Downloads; raises Cancelled."""
    root = default_picker_root()

    def find_candidates():
        # Bounded like `find -maxdepth 3` — don't descend into deep trees.
        results = []
        for dirpath, dirnames, filenames in os.walk(root):
            depth = len(Path(dirpath).relative_to(root).parts)
            if depth >= 3:
                dirnames.clear()
            for fn in filenames:
                if matches_mode(fn.lower(), mode):
                    results.append(Path(dirpath) / fn)
        return sorted(results)

    while True:
        if has_gum():
            candidates = find_candidates()
            if not candidates:
                print_warning(f"No matching files found in {root}")
                raise Cancelled()
            display = [str(p.relative_to(root)) for p in candidates]
            picked = gum_filter(display, header=header)
            if picked is None:
                raise Cancelled()
            selection = root / picked
        else:
            selection = Path(prompt_with_default(header, f"{root}/", "Enter a file path", True))

        try:
            selection = selection.resolve(strict=True)
        except OSError:
            print_warning("Please select an existing file.", file=sys.stderr)
            continue
        if not selection.is_file():
            print_warning("Please select an existing file.", file=sys.stderr)
            continue
        if mode in ("appimage", "package") and not matches_mode(selection.name.lower(), mode):
            wanted = ".AppImage" if mode == "appimage" else ".deb, .rpm, or .pkg.tar.*"
            print_warning(f"Please select a {wanted} file.", file=sys.stderr)
            continue
        return selection


# ── State files (bash-quoted KEY=VALUE, compatible with the shell version) ──


def read_env(path):
    data = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        tokens = shlex.split(value)
        data[key] = tokens[0] if tokens else ""
    return data


def write_env(path, mapping):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{k}={shlex.quote(v)}\n" for k, v in mapping.items()))


def metadata_file_for_name(app_name):
    return DISTROBOX_STATE_DIR / f"{slugify(app_name)}.env"


def source_file_for_name(app_name):
    return SOURCES_STATE_DIR / f"{slugify(app_name)}.env"


def save_distrobox_metadata(app_name, container, package_type, app_id, app_args=""):
    """Sole writer of distrobox/<slug>.env; returns the mapping it wrote.

    PACKAGE_NAME is resolved here rather than passed in or carried over: every
    save follows an install, update or adopt, any of which can change the
    package behind the desktop id, and all of them have entered the container
    already."""
    meta = {
        "APP_NAME": app_name,
        "CONTAINER": container,
        "PACKAGE_TYPE": package_type,
        "APP_ID": app_id,
        "APP_ARGS": app_args,
        "PACKAGE_NAME": query_distrobox_package_name(container, package_type, app_id,
                                                     allow_start=True),
    }
    write_env(metadata_file_for_name(app_name), meta)
    return meta


def load_distrobox_metadata(app_name):
    f = metadata_file_for_name(app_name)
    if not f.is_file():
        raise AppError(f"No saved metadata for app: {app_name}")
    return read_env(f)


def save_source_metadata(app_name, app_type, repo, pattern, version, prerelease=False):
    ensure_dirs()
    write_env(source_file_for_name(app_name), {
        "APP_NAME": app_name,
        "APP_TYPE": app_type,
        "SOURCE_REPO": repo,
        "ASSET_PATTERN": pattern,
        "VERSION": version,
        "PRERELEASE": "1" if prerelease else "0",
    })


def source_prerelease(src):
    """Channel flag from a source .env. Absent (pre-existing state files, and
    the shell version's format) reads as stable."""
    return src.get("PRERELEASE", "0") == "1"


def load_source_metadata(app_name):
    f = source_file_for_name(app_name)
    if not f.is_file():
        print_error(f"No update source saved for app: {app_name}")
        print_info(f'Attach one with: ./manage.sh apps set-source --name "{app_name}" --repo owner/repo')
        raise AppError("")
    return read_env(f)


def list_source_files():
    ensure_dirs()
    return sorted(SOURCES_STATE_DIR.glob("*.env"))


# ── AppImage handling ────────────────────────────────────────────────────────


@dataclass
class AppImageMeta:
    name: str = ""
    icon: str = ""
    mimetype: str = ""
    categories: str = ""


def _desktop_field(path, key):
    for line in Path(path).read_text(errors="replace").splitlines():
        if line.startswith(f"{key}="):
            return line[len(key) + 1:]
    return ""


def extract_appimage_metadata(appimage_path, extract_dir):
    """Extract the AppImage into extract_dir and read its desktop metadata.

    Best-effort: returns an empty AppImageMeta when extraction fails.
    """
    meta = AppImageMeta()
    appimage_path = Path(appimage_path)
    extract_dir = Path(extract_dir)

    with tempfile.TemporaryDirectory() as work_dir:
        appimage_path.chmod(appimage_path.stat().st_mode | 0o111)
        with Spinner("Extracting AppImage..."):
            res = subprocess.run([str(appimage_path), "--appimage-extract"],
                                 cwd=work_dir, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, check=False)
        squashfs = Path(work_dir) / "squashfs-root"
        if res.returncode != 0 or not squashfs.is_dir():
            return meta
        if extract_dir.exists():
            shutil.rmtree(extract_dir)
        shutil.move(str(squashfs), str(extract_dir))

    desktop_files = sorted(extract_dir.glob("*.desktop")) + sorted(extract_dir.glob("*/*.desktop"))
    desktop_files = [f for f in desktop_files if f.is_file()]
    icon_name = ""
    if desktop_files:
        df = desktop_files[0]
        meta.name = _desktop_field(df, "Name")
        # Carry over the upstream MIME associations and menu categories. Without
        # MimeType (and a %U in Exec) KDE/KIO treats the app as unable to open
        # URLs and silently falls back to another handler from mimeinfo.cache.
        meta.mimetype = _desktop_field(df, "MimeType")
        meta.categories = _desktop_field(df, "Categories")
        icon_name = _desktop_field(df, "Icon")

    def find_first(predicate):
        # Follow symlinks: AppImages typically symlink their root icon.
        for dirpath, _dirnames, filenames in os.walk(extract_dir, followlinks=True):
            for fn in sorted(filenames):
                p = Path(dirpath) / fn
                if predicate(fn) and p.is_file():
                    return str(p)
        return ""

    if icon_name:
        # Only accept real image extensions; a bare "$icon_name" match is NOT
        # trusted — Electron apps ship the app *binary* under the same name
        # (Icon=zulip vs ELF ./zulip), which used to get installed as the icon.
        exts = (f"{icon_name}.png", f"{icon_name}.svg", f"{icon_name}.xpm")
        meta.icon = find_first(lambda fn: fn in exts)

    if not meta.icon:
        # .DirIcon is the AppImage-spec icon (a PNG, usually a symlink)
        diricon = extract_dir / ".DirIcon"
        if diricon.is_file():
            meta.icon = str(diricon)
        else:
            meta.icon = find_first(lambda fn: fn.endswith((".png", ".svg", ".xpm")))
    return meta


def detect_appimage_name(appimage_path, extract_dir):
    """Extract metadata and resolve the display name (embedded or humanized)."""
    meta = extract_appimage_metadata(appimage_path, extract_dir)
    name = meta.name or humanize_appimage_name(Path(appimage_path).name)
    return meta, name


def execute_import_appimage(source_path, app_name, meta=None):
    ensure_dirs()
    require_file(source_path)

    if meta is None:
        with tempfile.TemporaryDirectory() as extract_dir:
            meta = extract_appimage_metadata(source_path, Path(extract_dir) / "root")
            return _finish_import_appimage(source_path, app_name, meta)
    return _finish_import_appimage(source_path, app_name, meta)


def _finish_import_appimage(source_path, app_name, meta):
    slug = slugify(app_name)
    dest_appimage = APPIMAGE_DIR / f"{slug}.AppImage"
    install_file(source_path, dest_appimage, 0o755)

    icon_path = ""
    if meta.icon and Path(meta.icon).is_file():
        # Extensionless icons (.DirIcon & friends) are PNG per the AppImage spec.
        ext = Path(meta.icon).name.rsplit(".", 1)[-1].lower()
        if ext not in ("png", "svg", "xpm"):
            ext = "png"
        icon_path = APP_ICON_DIR / f"{slug}.{ext}"
        install_file(meta.icon, icon_path, 0o644)

    desktop_file = APP_DESKTOP_DIR / f"{slug}.desktop"
    # %U is load-bearing: without a URL field code, KDE/KIO considers the app
    # unable to open links and falls back to another x-scheme-handler from
    # mimeinfo.cache (e.g. Chrome) even when this app is the mimeapps default.
    content = (
        "[Desktop Entry]\n"
        f"Name={app_name}\n"
        f"Exec={dest_appimage} %U\n"
        "Type=Application\n"
        f"Categories={meta.categories or 'Utility;'}\n"
        "Terminal=false\n"
        "StartupNotify=true\n"
    )
    if meta.mimetype:
        content += f"MimeType={meta.mimetype}\n"
    if icon_path:
        content += f"Icon={icon_path}\n"
    desktop_file.write_text(content)

    refresh_desktop_db()
    print_success("Imported AppImage into the launcher")
    print(f"  AppImage: {dest_appimage}")
    print(f"  Desktop entry: {desktop_file}")
    if icon_path:
        print(f"  Icon: {icon_path}")


def list_installed_appimages():
    ensure_dirs()
    return sorted(APPIMAGE_DIR.glob("*.AppImage"))


def execute_remove_appimage(appimage_path):
    appimage_path = Path(appimage_path)
    slug = appimage_path.name.removesuffix(".AppImage")
    removed = []

    appimage_path.unlink(missing_ok=True)
    removed.append(f"AppImage: {appimage_path}")

    desktop_file = APP_DESKTOP_DIR / f"{slug}.desktop"
    if desktop_file.is_file():
        desktop_file.unlink()
        removed.append(f"Desktop entry: {desktop_file}")

    for icon in sorted(APP_ICON_DIR.glob(f"{slug}.*")):
        icon.unlink()
        removed.append(f"Icon: {icon}")

    source_file = SOURCES_STATE_DIR / f"{slug}.env"
    if source_file.is_file():
        source_file.unlink()
        removed.append(f"Update source: {source_file}")

    refresh_desktop_db()
    print_success("Removed AppImage")
    for line in removed:
        print(f"  {line}")


# ── Distrobox handling ───────────────────────────────────────────────────────


def require_distrobox():
    if not command_exists("distrobox-enter"):
        raise AppError("distrobox-enter not found. Is Distrobox installed?")


def package_type_for_file(path):
    name = Path(path).name
    if name.endswith(".deb"):
        return "deb"
    if name.endswith(".rpm"):
        return "rpm"
    if name.endswith(".pkg.tar") or ".pkg.tar." in name:
        return "arch"
    print_error(f"Unsupported package format: {path}")
    print_info("Supported: .deb, .rpm, .pkg.tar.*")
    raise AppError("")


def run_in_distrobox(container, *args, capture=False):
    cmd = ["distrobox-enter", "--name", container, "--no-tty", "--", *args]
    if capture:
        return subprocess.run(cmd, capture_output=True, text=True, check=False)
    return subprocess.run(cmd, check=False)


RESOLVE_PKG_PATH_SNIPPET = """\
host_pkg="$1"
if [ -f "$host_pkg" ]; then
    pkg_path="$host_pkg"
elif [ -f "/run/host$host_pkg" ]; then
    pkg_path="/run/host$host_pkg"
else
    echo "ERROR: package file not visible inside container: $host_pkg" >&2
    exit 12
fi
"""

INSTALL_SNIPPETS = {
    "deb": """\
if command -v apt >/dev/null 2>&1; then
    sudo apt install -y "$pkg_path"
elif command -v dpkg >/dev/null 2>&1; then
    sudo dpkg -i "$pkg_path" || { sudo apt-get install -f -y && sudo dpkg -i "$pkg_path"; }
else
    echo "ERROR: no Debian package manager found in container" >&2
    exit 13
fi
""",
    "rpm": """\
if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y "$pkg_path"
elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y "$pkg_path"
elif command -v zypper >/dev/null 2>&1; then
    sudo zypper --non-interactive install "$pkg_path"
else
    echo "ERROR: no RPM package manager found in container" >&2
    exit 13
fi
""",
    "arch": """\
if command -v pacman >/dev/null 2>&1; then
    sudo pacman -U --noconfirm "$pkg_path"
else
    echo "ERROR: no pacman found in container" >&2
    exit 13
fi
""",
}

# Where an exported desktop entry can live inside a container. Shared so a
# desktop id discovered by list_desktop_ids_in_container is always resolvable
# back to a file by RESOLVE_DESKTOP_PATH_SNIPPET.
DESKTOP_DIRS_SH = '/usr/share/applications "$HOME/.local/share/applications"'

# Resolve an exported desktop id to its file inside the container, so the
# package manager can be asked which package owns it.
RESOLVE_DESKTOP_PATH_SNIPPET = f"""\
app_path=""
for d in {DESKTOP_DIRS_SH}; do
    if [ -f "$d/$1" ]; then app_path="$d/$1"; break; fi
done
"""

# Desktop id -> owning package name.
QUERY_OWNER_SNIPPETS = {
    "deb": 'dpkg -S "${app_path:-$1}" 2>/dev/null | head -1 | cut -d: -f1',
    "rpm": '[ -n "$app_path" ] && rpm -qf --qf \'%{NAME}\' "$app_path" 2>/dev/null',
    "arch": '[ -n "$app_path" ] && pacman -Qoq "$app_path" 2>/dev/null',
}

# Package name -> version currently installed in the container.
QUERY_VERSION_SNIPPETS = {
    "deb": 'dpkg-query -W -f \'${Version}\' "$1" 2>/dev/null',
    "rpm": 'rpm -q --qf \'%{VERSION}\' "$1" 2>/dev/null',
    "arch": 'pacman -Q "$1" 2>/dev/null | awk \'{print $2}\'',
}


@functools.lru_cache(maxsize=1)
def list_distrobox_container_states():
    """{container name: is it already running}, e.g. {'Falco': True}.

    Cached for the process: `distrobox list` is a ~50ms subprocess and every
    app checked asks for it. Invalidated on create; a container that a later
    command starts stays cached as stopped, which only makes a read-only
    version check fall back to recorded state — the same thing it does when the
    container really is stopped."""
    if command_exists("distrobox"):
        cmd = ["distrobox", "list"]
    elif command_exists("distrobox-list"):
        cmd = ["distrobox-list"]
    else:
        return {}
    res = subprocess.run([*cmd, "--no-color"], capture_output=True, text=True, check=False)
    if res.returncode != 0 or not res.stdout.strip():
        return {}
    lines = res.stdout.splitlines()
    # Locate columns via the header ("ID | NAME | STATUS | IMAGE"). (The former
    # shell version grabbed column 1 — the container *ID*.) Rows with a
    # different field count are wrap-around continuations; skip them.
    header = [h.strip().upper() for h in lines[0].split("|")]
    name_idx = header.index("NAME") if "NAME" in header else 0
    states = {}
    for line in lines[1:]:
        fields = [f.strip() for f in line.split("|")]
        if len(fields) != len(header) or not fields[name_idx]:
            continue
        # distrobox list sometimes emits garbage rows (image labels/mounts
        # rendered as a container); only accept valid podman container names.
        if re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", fields[name_idx]):
            row = dict(zip(header, fields))
            states[fields[name_idx]] = row.get("STATUS", "").lower().startswith("up")
    return states


def list_distrobox_containers():
    return sorted(list_distrobox_container_states())


def distrobox_container_running(container):
    """True only for an already-started container. Callers use this to avoid
    booting a container as a side effect of a read-only check."""
    return list_distrobox_container_states().get(container, False)


# Images matched to the package format; distrobox-enter would otherwise
# auto-create missing containers from its Fedora default, which can't
# install .deb or .pkg.tar packages.
DEFAULT_IMAGES = {
    "deb": "docker.io/library/ubuntu:latest",
    "rpm": "registry.fedoraproject.org/fedora-toolbox:latest",
    "arch": "docker.io/library/archlinux:latest",
}


def ensure_distrobox_container(container, package_type):
    if container in list_distrobox_container_states():
        return
    image = DEFAULT_IMAGES.get(package_type, "")
    print_info(f"Container '{container}' does not exist; creating it from {image}...")
    res = subprocess.run(["distrobox", "create", "--yes", "--name", container, "--image", image],
                         check=False)
    if res.returncode != 0:
        raise AppError(f"Failed to create container '{container}'")
    list_distrobox_container_states.cache_clear()


def pick_existing_distrobox_container():
    containers = list_distrobox_containers()
    if not containers:
        return prompt_with_default("Distrobox container name", "", "Enter a container name", True)

    manual = "Enter container name manually"
    choice = gum_choose([*containers, manual], header="Select a Distrobox container")
    if choice is None:
        raise Cancelled()
    if choice == manual:
        return prompt_with_default("Distrobox container name", "", "Enter a container name", True)
    return choice


def list_desktop_ids_in_container(container):
    """Desktop file basenames visible in the container; None when listing fails."""
    res = run_in_distrobox(container, "sh", "-lc",
                           f"find {DESKTOP_DIRS_SH} "
                           '-maxdepth 1 -type f -name "*.desktop" -printf "%f\\n" 2>/dev/null '
                           "| sort -u", capture=True)
    if res.returncode != 0:
        return None
    return [line for line in res.stdout.splitlines() if line]


def install_package_in_distrobox(container, package_path, package_type):
    script = RESOLVE_PKG_PATH_SNIPPET + INSTALL_SNIPPETS[package_type]
    res = run_in_distrobox(container, "sh", "-lc", script, "sh", str(package_path))
    return res.returncode == 0


# ── Live version of a Distrobox app ──────────────────────────────────────────
#
# The recorded VERSION in sources/<slug>.env is only ever written by this tool,
# so an app that updates itself inside its container (Electron's auto-updater
# shells out to the container's package manager) leaves it stale, and the app
# then reports an update that is already installed. Asking the container's
# package database instead makes the recorded value a fallback rather than the
# source of truth.


def _query_in_container(container, script, argument, allow_start):
    """Run a read-only query in the container. Returns '' for an unsupported
    package type (empty script), for a container that is stopped when
    allow_start is False, or when the query yields nothing."""
    if not (script and container and command_exists("distrobox-enter")):
        return ""
    if not allow_start and not distrobox_container_running(container):
        return ""
    res = run_in_distrobox(container, "sh", "-lc", script, "sh", argument, capture=True)
    lines = res.stdout.strip().splitlines() if res.returncode == 0 else []
    return lines[0].strip() if lines else ""


def query_distrobox_package_name(container, package_type, app_id, allow_start=False):
    """Ask the container which package owns the exported desktop entry."""
    owner_query = QUERY_OWNER_SNIPPETS.get(package_type, "")
    script = RESOLVE_DESKTOP_PATH_SNIPPET + owner_query if owner_query else ""
    return _query_in_container(container, script, app_id, allow_start)


def distrobox_package_name(meta, allow_start=False):
    """Package name backing a managed Distrobox app.

    Recorded by save_distrobox_metadata; state files written before PACKAGE_NAME
    existed are back-filled here, since a package name never changes for an
    installed app. The write is best-effort — it must not break a version
    check."""
    recorded = meta.get("PACKAGE_NAME", "")
    if recorded:
        return recorded

    name = query_distrobox_package_name(meta.get("CONTAINER", ""),
                                        meta.get("PACKAGE_TYPE", ""),
                                        meta.get("APP_ID", ""), allow_start)
    if name:
        try:
            write_env(metadata_file_for_name(meta["APP_NAME"]), {**meta, "PACKAGE_NAME": name})
        except (OSError, KeyError):
            pass
    return name


def distrobox_installed_version(meta, allow_start=False):
    """Version reported by the container's package manager, or '' if unknown."""
    package = distrobox_package_name(meta, allow_start)
    query = QUERY_VERSION_SNIPPETS.get(meta.get("PACKAGE_TYPE", ""), "")
    return _query_in_container(meta.get("CONTAINER", ""), query, package, allow_start) \
        if package else ""


def normalize_version(value):
    """Strip the decorations that differ between a GitHub tag and a native
    package version: the tag's leading 'v', an rpm/deb epoch, and a purely
    numeric package revision (upstream tags never carry one)."""
    v = (value or "").strip()
    v = re.sub(r"^\d+:", "", v)
    v = re.sub(r"^[vV](?=\d)", "", v)
    return re.sub(r"-\d+$", "", v)


def versions_match(tag, installed):
    if not tag or not installed:
        return False
    return normalize_version(tag) == normalize_version(installed)


def _natural_chunks(text):
    """Digit runs compare as numbers, letter runs as text, so rc9 precedes
    rc10. The leading 0/1 keeps the two kinds orderable against each other."""
    return tuple((1, int(p)) if p.isdigit() else (0, p)
                 for p in re.findall(r"\d+|[a-zA-Z]+", text.lower()))


def version_key(value):
    """Sortable key: the numeric release, then a prerelease suffix that sorts
    *before* the bare release it qualifies (1.2.3-beta1 < 1.2.3).

    Deliberately not `sort -V`, which manage-updates.sh uses for tool binaries:
    it orders 1.2.3-beta1 *after* 1.2.3. That is harmless for a self-reported
    binary version but wrong for release tags, where switching a repo to the
    pre-release channel would otherwise offer a beta of a release already
    installed."""
    release, _, suffix = normalize_version(value).partition("-")
    return (tuple(int(n) for n in re.findall(r"\d+", release)),
            (0, _natural_chunks(suffix)) if suffix else (1, ()))


def version_is_outdated(installed, latest):
    """True only when `latest` is genuinely newer than `installed`.

    Ordered rather than compared for inequality, so an installed version that
    has run *ahead* of the latest release reads as current instead of as an
    update the user can apply but never clear — then re-applies as a downgrade
    on the next run. A Distrobox app that updates itself in-container lands
    there routinely. manage-updates.sh takes these rows verbatim and never
    re-checks them, so this is the only place the ordering can be enforced."""
    if not latest:
        return False
    if not installed:
        return True
    return version_key(latest) > version_key(installed)


def installed_version_for_source(src, allow_start=False):
    """Best known installed version for a tracked app: live from the container
    for Distrobox apps, else the version this tool recorded."""
    recorded = src.get("VERSION", "")
    if src.get("APP_TYPE", "") != "distrobox":
        return recorded
    f = metadata_file_for_name(src.get("APP_NAME", ""))
    if not f.is_file():
        return recorded
    return distrobox_installed_version(read_env(f), allow_start) or recorded


def export_distrobox_app(container, app_id):
    app_id = app_id.removesuffix(".desktop")
    res = run_in_distrobox(container, "distrobox-export", "--app", app_id)
    return res.returncode == 0


def find_exported_desktop_file(app_id, container):
    """Host desktop file created by distrobox-export ("<container>-<appid>.desktop")."""
    base = Path(app_id).name.removesuffix(".desktop")
    for candidate in (APP_DESKTOP_DIR / f"{container}-{base}.desktop",
                      APP_DESKTOP_DIR / f"{base}.desktop"):
        if candidate.is_file():
            return candidate
    globbed = sorted(APP_DESKTOP_DIR.glob(f"*-{base}.desktop"))
    return globbed[0] if globbed else None


def apply_distrobox_app_args(app_id, container, app_args):
    """Re-inject saved launch args into the exported desktop file's Exec line(s).

    distrobox-export regenerates the desktop file on every install/update,
    dropping custom flags (e.g. --disable-gpu), so this must run after each
    export. Args are inserted before the first field code (%U/%F/...), or
    appended when none is present; lines already containing them are skipped.
    """
    if not app_args:
        return

    desktop_file = find_exported_desktop_file(app_id, container)
    if desktop_file is None:
        print_warning("Could not find the exported desktop file; launch args not applied.")
        return

    def inject(line):
        if not (line.startswith("Exec=") and "distrobox-enter" in line and app_args not in line):
            return line
        m = re.search(r"[ \t]*%[a-zA-Z]", line)
        if m:
            return f"{line[:m.start()]} {app_args}{line[m.start():]}"
        return f"{line.rstrip()} {app_args}"

    lines = desktop_file.read_text().splitlines()
    desktop_file.write_text("".join(f"{inject(line)}\n" for line in lines))

    print_info(f"Applied launch args to '{desktop_file.name}': {app_args}")
    refresh_desktop_db()


def select_exported_app_id(before, after, requested, interactive):
    """Resolve which desktop entry the package install added.

    interactive=True resolves ambiguity with a picker (raises Cancelled on
    cancel); otherwise ambiguity is an error.
    """
    if requested:
        return requested
    added = sorted(set(after) - set(before))

    if len(added) == 1:
        return added[0]

    if interactive:
        if len(added) > 1:
            picked = gum_choose(added, header="Pick the desktop entry to export")
            if picked is None:
                raise Cancelled()
            return picked
        return prompt_with_default("Desktop entry id", "", "example.desktop", True)

    if not added:
        print_error("Could not detect a new desktop entry automatically")
    else:
        print_error("Multiple desktop entries were added; please specify one with --app")
        for entry in added:
            print(f"  - {entry}")
    raise AppError("")


def execute_install_distrobox(container, package_path, app_name, requested_app_id,
                              app_args="", interactive=False):
    """One install pipeline for both the CLI and the interactive wizard."""
    ensure_dirs()
    require_distrobox()
    require_file(package_path)
    package_type = package_type_for_file(package_path)
    ensure_distrobox_container(container, package_type)

    print_info(f"Collecting desktop entries from container '{container}'...")
    before = list_desktop_ids_in_container(container)
    if before is None:
        raise AppError(f"Could not list desktop entries in container '{container}'.")

    print_info(f"Installing package in container '{container}'...")
    if not install_package_in_distrobox(container, package_path, package_type):
        raise AppError("Package installation failed.")

    print_info("Collecting updated desktop entries...")
    after = list_desktop_ids_in_container(container)
    if after is None:
        raise AppError(f"Could not list desktop entries in container '{container}'.")

    app_id = select_exported_app_id(before, after, requested_app_id, interactive)
    if not app_name:
        app_name = app_id.removesuffix(".desktop")

    print_info(f"Exporting '{app_id}' to the host launcher...")
    if not export_distrobox_app(container, app_id):
        raise AppError("Export failed.")
    apply_distrobox_app_args(app_id, container, app_args)
    save_distrobox_metadata(app_name, container, package_type, app_id, app_args)

    print_success("Installed and exported Distrobox app")
    print(f"  App: {app_name}")
    print(f"  Container: {container}")
    print(f"  Desktop entry: {app_id}")
    if app_args:
        print(f"  Launch args: {app_args}")
    return app_name


def execute_update_distrobox(app_name, package_path, app_args_override=None):
    """Update a managed app; app_args_override=None preserves the saved args."""
    ensure_dirs()
    require_distrobox()
    require_file(package_path)
    meta = load_distrobox_metadata(app_name)

    app_args = meta.get("APP_ARGS", "") if app_args_override is None else app_args_override

    new_type = package_type_for_file(package_path)
    if new_type != meta["PACKAGE_TYPE"]:
        print_warning(f"Saved package type is '{meta['PACKAGE_TYPE']}' but new file looks like '{new_type}'")

    print_info(f"Updating '{meta['APP_NAME']}' in container '{meta['CONTAINER']}'...")
    if not install_package_in_distrobox(meta["CONTAINER"], package_path, new_type):
        raise AppError("Package update failed.")

    print_info(f"Refreshing exported desktop entry '{meta['APP_ID']}'...")
    if not export_distrobox_app(meta["CONTAINER"], meta["APP_ID"]):
        raise AppError("Export refresh failed.")
    apply_distrobox_app_args(meta["APP_ID"], meta["CONTAINER"], app_args)
    save_distrobox_metadata(meta["APP_NAME"], meta["CONTAINER"], new_type, meta["APP_ID"], app_args)

    print_success("Updated Distrobox app")
    print(f"  App: {meta['APP_NAME']}")
    print(f"  Container: {meta['CONTAINER']}")
    print(f"  Desktop entry: {meta['APP_ID']}")
    if app_args:
        print(f"  Launch args: {app_args}")


def execute_remove_distrobox(metadata_file):
    meta = read_env(metadata_file)
    app_id, container = meta["APP_ID"], meta["CONTAINER"]

    print_info(f"Removing exported app '{app_id}' from container '{container}'...")
    # Best-effort: the exported entry may already be gone.
    subprocess.run(
        ["distrobox-enter", "--name", container, "--no-tty", "--",
         "distrobox-export", "--delete", "--app", app_id],
        stderr=subprocess.DEVNULL, check=False)

    # Clean up lingering host desktop files (distrobox names them container-appid)
    base = Path(app_id).name.removesuffix(".desktop")
    lingering = [APP_DESKTOP_DIR / f"{base}.desktop", *APP_DESKTOP_DIR.glob(f"*-{base}.desktop")]
    for f in lingering:
        Path(f).unlink(missing_ok=True)

    Path(metadata_file).unlink(missing_ok=True)
    source_file_for_name(meta["APP_NAME"]).unlink(missing_ok=True)
    refresh_desktop_db()

    print_success("Removed Distrobox app")
    print(f"  App: {meta['APP_NAME']}")
    print(f"  Container: {container}")
    print(f"  Desktop entry: {app_id}")


# ── GitHub release sources ───────────────────────────────────────────────────
# Per-app source metadata lives in SOURCES_STATE_DIR/<slug>.env and records
# where an app can be re-downloaded from for updates:
#   APP_NAME       display name (its slug ties it to the AppImage / Distrobox app)
#   APP_TYPE       appimage | distrobox
#   SOURCE_REPO    GitHub owner/repo
#   ASSET_PATTERN  glob matched against release asset filenames
#   VERSION        installed release tag ('' = unknown → reported as updatable)


def github_normalize_repo(repo_input):
    """Accept "owner/repo" or any github.com URL form and normalize."""
    repo = repo_input
    for prefix in ("https://", "http://", "www.", "github.com/"):
        repo = repo.removeprefix(prefix)
    repo = "/".join(repo.split("/")[:2]).removesuffix(".git")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise AppError(f"Not a GitHub repo: {repo_input} (expected owner/repo or a github.com URL)")
    return repo


_HTTP_HEADERS = {
    "User-Agent": "dotfiles-external-apps",
    "Accept": "application/vnd.github+json",
}

# Session cache of release JSON per (repo, prerelease): a check followed by an
# update in the same run reuses the response instead of re-hitting the API.
# The channel is part of the key — the same repo resolves to different releases
# on the stable and prerelease channels.
_release_cache = {}
_release_cache_lock = threading.Lock()

# Epoch second the rate limit resets, set when the API refuses a request for
# quota. Recorded rather than raised: a scan should still report the repos it
# did resolve, and the caller decides how to explain the gaps.
_rate_limit_reset = None
_rate_limit_lock = threading.Lock()


@functools.lru_cache(maxsize=1)
def gh_token():
    """The gh CLI's token, or None. Looked up once per session.

    Unauthenticated api.github.com allows 60 requests/hour, which one update
    scan plus an app check can plausibly exhaust; an authenticated call gets
    5000. gh is how this repo already talks to GitHub, so its existing login is
    reused rather than asking for a separate token.
    """
    if not command_exists("gh"):
        return None
    try:
        out = subprocess.run(["gh", "auth", "token"], capture_output=True,
                             text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() or None if out.returncode == 0 else None


def note_rate_limit(headers):
    """Record a quota refusal, distinguishing it from other 403s."""
    global _rate_limit_reset
    # HTTPError.headers is an email.message.Message — already case-insensitive.
    if headers.get("x-ratelimit-remaining") != "0":
        return
    with _rate_limit_lock:
        try:
            _rate_limit_reset = int(headers.get("x-ratelimit-reset") or 0)
        except ValueError:
            _rate_limit_reset = 0


def rate_limit_reset():
    with _rate_limit_lock:
        return _rate_limit_reset


def rate_limit_note():
    """Local clock time the quota resets, for a human-facing message."""
    reset = rate_limit_reset()
    if not reset:
        return "an unknown time"
    try:
        return time.strftime("%H:%M", time.localtime(reset))
    except (ValueError, OSError):
        return "an unknown time"


def channel_label(prerelease):
    return "pre-release" if prerelease else "stable"


def _gh_get_json(url):
    """GET a GitHub API URL and parse it; None on any failure (rate limit noted)."""
    headers = dict(_HTTP_HEADERS)
    token = gh_token()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers),
                                    timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        # A 403/429 with no quota left is a rate limit, not a missing repo —
        # worth telling the user apart from "this repo has no releases".
        if e.code in (403, 429) and e.headers:
            note_rate_limit(e.headers)
        return None
    except (urllib.error.URLError, json.JSONDecodeError, OSError):
        # Failures are not cached, so a later call in the same run retries
        # (matches the shell version, which only cached successful fetches).
        return None


def gh_release_json(repo, prerelease=False):
    """Newest release JSON dict for a repo on the requested channel, fetched
    once per session; None on failure.

    Stable uses /releases/latest, which GitHub defines as excluding drafts and
    pre-releases. The pre-release channel has no such endpoint, so it reads the
    first page of /releases (newest first) and takes the newest non-draft entry
    — that is the nightly/beta tag when one is ahead of the last stable, and the
    stable tag otherwise.
    """
    key = (repo, bool(prerelease))
    with _release_cache_lock:
        if key in _release_cache:
            return _release_cache[key]
    # Once the quota is gone every further request is a guaranteed 403, so stop
    # paying for the round trips — the rest of the batch reports as unresolved.
    if rate_limit_reset() is not None:
        return None

    if prerelease:
        # 30 is GitHub's default page size and plenty: a repo publishing more
        # than 30 releases between two checks is not a channel worth tracking.
        listing = _gh_get_json(f"https://api.github.com/repos/{repo}/releases?per_page=30")
        if not isinstance(listing, list):
            return None
        data = next((r for r in listing if isinstance(r, dict) and not r.get("draft")), None)
        if data is None:
            return None
    else:
        data = _gh_get_json(f"https://api.github.com/repos/{repo}/releases/latest")
        if data is None:
            return None

    with _release_cache_lock:
        _release_cache[key] = data
    return data


def prefetch_release_json(targets):
    """Warm the release cache concurrently. Accepts repo strings or
    (repo, prerelease) pairs — a repo tracked on both channels is two fetches."""
    pairs = sorted({(t, False) if isinstance(t, str) else (t[0], bool(t[1])) for t in targets})
    if not pairs:
        return
    # Resolve the token before fanning out, so the workers don't queue behind
    # one thread's `gh auth token` subprocess.
    gh_token()
    # Wide enough for a whole update scan (a dozen-odd repos) in one wave: these
    # are independent one-shot GETs, so a narrower pool just adds a round trip.
    with ThreadPoolExecutor(max_workers=min(16, len(pairs))) as pool:
        list(pool.map(lambda p: gh_release_json(*p), pairs))


def github_latest_tag(repo, prerelease=False):
    return (gh_release_json(repo, prerelease) or {}).get("tag_name") or ""


def github_fetch_latest_release(repo, prerelease=False):
    """Newest release tag + asset URLs on a channel; raises AppError with details."""
    what = "newest pre-release" if prerelease else "latest release"
    with Spinner(f"Fetching {what} of {repo}..."):
        data = gh_release_json(repo, prerelease)
    tag = (data or {}).get("tag_name") or ""
    assets = [a.get("browser_download_url", "") for a in (data or {}).get("assets", [])]
    assets = [u for u in assets if u]

    if not tag:
        raise AppError(f"Could not fetch the {what} of {repo}")
    if not assets:
        raise AppError(f"The {what} of {repo} ({tag}) has no downloadable assets")
    return tag, assets


# Keywords identifying the current CPU arch in asset filenames, and those of
# other arches (used to drop e.g. arm64 assets on an x86_64 host).
_ARCH_KEYWORDS = {
    "x86_64": ("x86_64 x86-64 amd64 x64", "aarch64 arm64 armhf armv7 i686 i386"),
    "aarch64": ("aarch64 arm64", "x86_64 x86-64 amd64 x64 armhf armv7 i686 i386"),
    "arm64": ("aarch64 arm64", "x86_64 x86-64 amd64 x64 armhf armv7 i686 i386"),
}

SIDECAR_SUFFIXES = (".zsync", ".blockmap", ".sha256", ".sha256sum", ".sha512",
                    ".sig", ".asc", ".txt", ".yml", ".yaml", ".json")


def filter_release_assets(asset_urls, pattern, type_filter):
    """Filter release assets down to installable candidates.

    Sidecar files (.zsync, checksums, …) and other-arch assets are dropped;
    assets naming the current arch are preferred over arch-less ones.
    """
    arch_kw, other_kw = _ARCH_KEYWORDS.get(platform.machine(), ("", ""))
    arch_kw, other_kw = arch_kw.split(), other_kw.split()
    pattern_lower = pattern.lower()

    primary, fallback = [], []
    for url in asset_urls:
        name_lower = url.rsplit("/", 1)[-1].lower()

        if name_lower.endswith(SIDECAR_SUFFIXES):
            continue
        if type_filter == "appimage":
            if not matches_mode(name_lower, "appimage"):
                continue
        elif type_filter == "package":
            if not matches_mode(name_lower, "package"):
                continue
        elif not matches_mode(name_lower, "all"):
            continue
        if pattern_lower and not fnmatch.fnmatchcase(name_lower, pattern_lower):
            continue

        has_arch = any(kw in name_lower for kw in arch_kw)
        # Drop assets that name another arch (unless they also name ours,
        # e.g. "x64" inside "linux-x64")
        if not has_arch and any(kw in name_lower for kw in other_kw):
            continue
        (primary if has_arch else fallback).append(url)

    return primary or fallback


def derive_asset_pattern(name, tag):
    """Concrete asset filename → reusable glob (version replaced with '*')."""
    bare = tag.removeprefix("v")
    if bare and bare in name:
        return name.replace(bare, "*")
    if tag and tag in name:
        return name.replace(tag, "*")
    return name


def pick_release_asset(asset_urls, pattern, type_filter, interactive):
    """Resolve exactly one asset URL. With several matches: ask (interactive)
    or take the first (non-interactive, e.g. update --all)."""
    candidates = filter_release_assets(asset_urls, pattern, type_filter)

    if not candidates:
        suffix = f" pattern '{pattern}'" if pattern else ""
        print_error(f"No release asset matches{suffix} (type: {type_filter or 'any'})", file=sys.stderr)
        print_info("Assets in this release:", file=sys.stderr)
        for url in asset_urls:
            print(f"  - {url.rsplit('/', 1)[-1]}", file=sys.stderr)
        raise AppError("")

    if len(candidates) == 1:
        return candidates[0]

    if interactive and has_gum():
        names = [u.rsplit("/", 1)[-1] for u in candidates]
        picked = gum_choose(names, header="Pick the release asset to install")
        if picked is None:
            raise Cancelled()
        return candidates[names.index(picked)]

    first = candidates[0].rsplit("/", 1)[-1]
    print_warning(f"Multiple assets match; using {first} (pass --asset to pin one)", file=sys.stderr)
    return candidates[0]


def download_release_asset(url):
    """Download into a fresh temp dir, keeping the real filename (package type
    detection relies on the extension). Caller removes the parent dir."""
    name = url.rsplit("/", 1)[-1]
    download_dir = Path(tempfile.mkdtemp())
    dest = download_dir / name
    try:
        with Spinner(f"Downloading {name}..."), \
             urllib.request.urlopen(urllib.request.Request(url, headers=_HTTP_HEADERS),
                                    timeout=60) as resp, \
             open(dest, "wb") as f:
            shutil.copyfileobj(resp, f)
    except (urllib.error.URLError, OSError):
        shutil.rmtree(download_dir, ignore_errors=True)
        raise AppError(f"Download failed: {url}")
    return dest


# ── Commands ─────────────────────────────────────────────────────────────────


def parse_flags(argv, value_flags=(), bool_flags=(), max_positional=0):
    """Tiny bash-style flag parser. Returns (flags, positionals, seen) or None
    when --help was passed; raises AppError on unexpected arguments."""
    flags, positionals, seen = {}, [], set()
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("--help", "-h"):
            return None
        if arg in value_flags:
            if i + 1 >= len(argv):
                raise AppError(f"Missing value for {arg}")
            flags[arg] = argv[i + 1]
            seen.add(arg)
            i += 2
        elif arg in bool_flags:
            flags[arg] = True
            seen.add(arg)
            i += 1
        elif len(positionals) < max_positional and not arg.startswith("--"):
            positionals.append(arg)
            i += 1
        else:
            raise AppError(f"Unexpected argument: {arg}")
    return flags, positionals, seen


def cmd_import_appimage(argv):
    parsed = parse_flags(argv, value_flags=("--name",), max_positional=1)
    if parsed is None:
        print(USAGE)
        return 0
    flags, positionals, _ = parsed
    if not positionals:
        print_error("Missing AppImage file path")
        print(USAGE)
        return 1

    source_path = Path(positionals[0]).resolve()
    require_file(source_path)
    app_name = flags.get("--name", "")

    if app_name:
        execute_import_appimage(source_path, app_name)
    else:
        with tempfile.TemporaryDirectory() as tmp:
            extract_dir = Path(tmp) / "root"
            meta, app_name = detect_appimage_name(source_path, extract_dir)
            execute_import_appimage(source_path, app_name, meta)
    return 0


def cmd_remove_appimage(argv):
    parsed = parse_flags(argv, value_flags=("--name",), max_positional=1)
    if parsed is None:
        print(USAGE)
        return 0
    flags, positionals, _ = parsed
    app_name = flags.get("--name") or (positionals[0] if positionals else "")
    if not app_name:
        print_error("Missing AppImage name")
        print(USAGE)
        return 1

    appimage_path = APPIMAGE_DIR / f"{slugify(app_name)}.AppImage"
    if not appimage_path.is_file():
        raise AppError(f"AppImage not found: {appimage_path}")
    execute_remove_appimage(appimage_path)
    return 0


def cmd_install_distrobox(argv):
    parsed = parse_flags(argv, value_flags=("--container", "--package", "--app", "--name", "--args"))
    if parsed is None:
        print(USAGE)
        return 0
    flags, _, _ = parsed
    container, package = flags.get("--container", ""), flags.get("--package", "")
    if not container or not package:
        print_error("install-distrobox requires --container and --package")
        print(USAGE)
        return 1

    execute_install_distrobox(container, Path(package).resolve(),
                              flags.get("--name", ""), flags.get("--app", ""),
                              flags.get("--args", ""))
    return 0


def cmd_update_distrobox(argv):
    parsed = parse_flags(argv, value_flags=("--name", "--package", "--args"))
    if parsed is None:
        print(USAGE)
        return 0
    flags, _, seen = parsed
    app_name, package = flags.get("--name", ""), flags.get("--package", "")
    if not app_name or not package:
        print_error("update-distrobox requires --name and --package")
        print(USAGE)
        return 1

    override = flags.get("--args", "") if "--args" in seen else None
    execute_update_distrobox(app_name, Path(package).resolve(), override)
    return 0


def cmd_install_github(argv):
    parsed = parse_flags(argv,
                         value_flags=("--name", "--asset", "--type", "--container", "--app", "--args"),
                         bool_flags=("--non-interactive", "--prerelease"), max_positional=1)
    if parsed is None:
        print(USAGE)
        return 0
    flags, positionals, _ = parsed
    if not positionals:
        print_error("install-github requires a GitHub repo (owner/repo or URL)")
        print(USAGE)
        return 1

    type_filter = flags.get("--type", "")
    if type_filter not in ("", "appimage", "package"):
        raise AppError(f"Invalid --type: {type_filter} (expected appimage or package)")

    interactive = "--non-interactive" not in flags
    prerelease = "--prerelease" in flags
    app_name = flags.get("--name", "")
    container = flags.get("--container", "")
    asset_pattern = flags.get("--asset", "")

    repo = github_normalize_repo(positionals[0])
    tag, asset_urls = github_fetch_latest_release(repo, prerelease)
    print_info(f"Latest {channel_label(prerelease)} of {repo}: {tag}")

    # --container implies a distro package install
    if not type_filter and container:
        type_filter = "package"

    asset_url = pick_release_asset(asset_urls, asset_pattern, type_filter, interactive)
    asset_name = asset_url.rsplit("/", 1)[-1]

    # Remember a version-agnostic pattern so updates match future releases
    if not asset_pattern:
        asset_pattern = derive_asset_pattern(asset_name, tag)

    asset_path = download_release_asset(asset_url)
    try:
        name_lower = asset_name.lower()
        if name_lower.endswith(".appimage"):
            app_type = "appimage"
            if app_name:
                execute_import_appimage(asset_path, app_name)
            else:
                with tempfile.TemporaryDirectory() as tmp:
                    meta, app_name = detect_appimage_name(asset_path, Path(tmp) / "root")
                    execute_import_appimage(asset_path, app_name, meta)
        elif matches_mode(name_lower, "package"):
            app_type = "distrobox"
            if not container:
                if interactive:
                    container = pick_existing_distrobox_container()
                else:
                    raise AppError("Package assets need --container NAME")
            if not app_name:
                app_name = humanize_appimage_name(asset_name)
            app_name = execute_install_distrobox(container, asset_path, app_name,
                                                 flags.get("--app", ""), flags.get("--args", ""),
                                                 interactive)
        else:
            raise AppError(f"Unsupported asset type: {asset_name}")
    finally:
        shutil.rmtree(asset_path.parent, ignore_errors=True)

    save_source_metadata(app_name, app_type, repo, asset_pattern, tag, prerelease)
    print_success(f"Pinned update source for {app_name}")
    print(f"  Repo: {repo}")
    print(f"  Channel: {channel_label(prerelease)}")
    print(f"  Version: {tag}")
    print(f"  Asset pattern: {asset_pattern}")
    return 0


def execute_set_source(app_name, repo_input, asset_pattern, version, prerelease=False):
    ensure_dirs()
    slug = slugify(app_name)

    if (APPIMAGE_DIR / f"{slug}.AppImage").is_file():
        app_type = "appimage"
    elif (DISTROBOX_STATE_DIR / f"{slug}.env").is_file():
        app_type = "distrobox"
    else:
        print_error(f"No installed app named '{app_name}' (no AppImage or managed Distrobox app)")
        print_info("Install it first, or check './manage.sh apps list'")
        raise AppError("")

    repo = github_normalize_repo(repo_input)
    tag, asset_urls = github_fetch_latest_release(repo, prerelease)

    # Make sure the pattern (or the type default) matches something downloadable.
    # This is what catches a channel switch whose saved pattern only matched the
    # old channel's filenames — better a hard error here than at update time.
    type_filter = "appimage" if app_type == "appimage" else "package"
    asset_url = pick_release_asset(asset_urls, asset_pattern, type_filter, False)
    if not asset_pattern:
        asset_pattern = derive_asset_pattern(asset_url.rsplit("/", 1)[-1], tag)

    save_source_metadata(app_name, app_type, repo, asset_pattern, version, prerelease)
    print_success(f"Saved update source for {app_name}")
    print(f"  Repo: {repo}")
    print(f"  Channel: {channel_label(prerelease)} (latest: {tag})")
    print(f"  Asset pattern: {asset_pattern}")
    if version:
        print(f"  Installed version: {version}")
    else:
        print("  Installed version: unknown — it will show as updatable until the first 'update' runs")
    if version and version != tag:
        print_info(f"Run './manage.sh apps update --name \"{app_name}\"' to move onto {tag}")


def cmd_set_source(argv):
    parsed = parse_flags(argv, value_flags=("--name", "--repo", "--asset", "--version"),
                         bool_flags=("--prerelease", "--stable"))
    if parsed is None:
        print(USAGE)
        return 0
    flags, _, _ = parsed
    if not flags.get("--name"):
        print_error("set-source requires --name")
        print(USAGE)
        return 1
    if "--prerelease" in flags and "--stable" in flags:
        raise AppError("--prerelease and --stable are mutually exclusive")

    app_name = flags["--name"]
    # Everything but --name may be inherited from the saved source, so switching
    # channel on a tracked app is just: set-source --name APP --stable
    saved = {}
    src_file = source_file_for_name(app_name)
    if src_file.is_file():
        saved = read_env(src_file)

    repo = flags.get("--repo") or saved.get("SOURCE_REPO", "")
    if not repo:
        print_error(f"set-source requires --repo (no source is saved for '{app_name}' yet)")
        print(USAGE)
        return 1

    if "--prerelease" in flags:
        prerelease = True
    elif "--stable" in flags:
        prerelease = False
    else:
        prerelease = source_prerelease(saved)

    execute_set_source(app_name, repo,
                       flags.get("--asset", "") or saved.get("ASSET_PATTERN", ""),
                       flags.get("--version", "") or saved.get("VERSION", ""),
                       prerelease)
    return 0


def collect_update_report(files, quiet):
    """Prefetch all release JSON and compare versions. Returns
    (up_to_date, outdated, failed) where outdated is [(name, installed, latest)]."""
    sources = [read_env(f) for f in files]
    installed_versions = []
    with Spinner(f"Checking {len(files)} app(s) for updates...") if not quiet else _null_ctx():
        prefetch_release_json((s.get("SOURCE_REPO", ""), source_prerelease(s))
                              for s in sources if s.get("SOURCE_REPO"))
        # Read-only: a stopped container is left stopped and its recorded
        # version used, rather than booting it just to answer a check. Entering
        # a running one costs ~0.4s, so the apps go out in one wave like the
        # release fetches, not serially behind them.
        with ThreadPoolExecutor(max_workers=min(8, len(sources) or 1)) as pool:
            installed_versions = list(pool.map(installed_version_for_source, sources))

    up_to_date, outdated, failed = [], [], []
    for src, installed in zip(sources, installed_versions):
        name = src.get("APP_NAME", "")
        latest = github_latest_tag(src.get("SOURCE_REPO", ""), source_prerelease(src))
        if not latest:
            failed.append((name, src.get("SOURCE_REPO", "")))
        elif not version_is_outdated(installed, latest):
            # What is on disk, not `latest`: the two differ whenever the app
            # has run ahead of its tracked release, which is the case this
            # ordering exists for.
            up_to_date.append((name, installed or latest))
        else:
            outdated.append((name, installed or "unknown", latest))
    return up_to_date, outdated, failed


class _null_ctx:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def cmd_check_updates(argv):
    porcelain = argv[:1] == ["--porcelain"]
    files = list_source_files()

    if not files:
        if not porcelain:
            print_info("No apps have an update source. Use 'install-github' or 'set-source' first.")
        return 0

    up_to_date, outdated, failed = collect_update_report(files, quiet=porcelain)

    if porcelain:
        for name, installed, latest in outdated:
            print(f"{name}|{installed}|{latest}")
        # Failures must be emitted too: without them a consumer cannot tell an
        # app that is current from one whose check never completed, and would
        # report "up to date" for both.
        for name, repo in failed:
            print(f"FAIL|{name}|{repo}")
        if rate_limit_reset() is not None:
            print(f"#ratelimit|{rate_limit_reset()}")
        return 0

    for name, repo in failed:
        print_warning(f"{name}: could not fetch the latest release of {repo}")
    if rate_limit_reset() is not None:
        print_warning(f"GitHub API rate limit reached — resets at {rate_limit_note()}")
    for name, version in up_to_date:
        print_success(f"{name} is up to date ({version})")
    for name, installed, latest in outdated:
        print_warning(f"{name}: update available ({installed} → {latest})")

    if not outdated and not failed:
        print_success("All external apps are up to date")
    elif outdated:
        print_info("Run './manage.sh apps update --all' (or update --name <app>) to update")
    return 0


def execute_update_from_source(lookup_name):
    src = load_source_metadata(lookup_name)
    name, app_type = src["APP_NAME"], src["APP_TYPE"]
    repo, pattern, installed = src["SOURCE_REPO"], src["ASSET_PATTERN"], src.get("VERSION", "")
    prerelease = source_prerelease(src)

    tag, asset_urls = github_fetch_latest_release(repo, prerelease)

    # This command is about to enter the container regardless, so starting it
    # to read the real version costs nothing extra — and saves re-downloading
    # a release the app already installed by itself.
    live = installed_version_for_source(src, allow_start=True)
    if not version_is_outdated(live, tag):
        print_info(f"{name} is already up to date ({live or 'unknown'})")
        # VERSION records the tag we consider installed, so compare tag to tag
        # — and only re-stamp it when the container really is on that release,
        # never when it has run ahead of it.
        if tag != installed and versions_match(tag, live):
            save_source_metadata(name, app_type, repo, pattern, tag, prerelease)
            print_info(f"Recorded version re-synced ({installed or 'unknown'} → {tag})")
        return
    print_info(f"Updating {name}: {live or 'unknown'} → {tag}")

    type_filter = "appimage" if app_type == "appimage" else "package"
    asset_url = pick_release_asset(asset_urls, pattern, type_filter, False)

    asset_path = download_release_asset(asset_url)
    try:
        if app_type == "appimage":
            # Same name → same slug → replaces the AppImage + desktop entry in place
            execute_import_appimage(asset_path, name)
        else:
            # Reinstalls in the saved container; launch args are preserved
            execute_update_distrobox(name, asset_path)
    finally:
        shutil.rmtree(asset_path.parent, ignore_errors=True)

    save_source_metadata(name, app_type, repo, pattern, tag, prerelease)
    print_success(f"{name} updated to {tag}")


def cmd_update_app(argv):
    parsed = parse_flags(argv, value_flags=("--name",), bool_flags=("--all",), max_positional=1)
    if parsed is None:
        print(USAGE)
        return 0
    flags, positionals, _ = parsed
    app_name = flags.get("--name") or (positionals[0] if positionals else "")

    if flags.get("--all"):
        files = list_source_files()
        if not files:
            print_info("No apps have an update source.")
            return 0
        rc = 0
        for f in files:
            name = read_env(f).get("APP_NAME", "")
            try:
                execute_update_from_source(name)
            except AppError as e:
                if str(e):
                    print_error(str(e))
                rc = 1
        return rc

    if not app_name:
        print_error("update requires --name NAME or --all")
        print(USAGE)
        return 1
    execute_update_from_source(app_name)
    return 0


# ── Listing ──────────────────────────────────────────────────────────────────


def desktop_entry_name(path):
    return _desktop_field(path, "Name")


def desktop_entry_container(path):
    for line in Path(path).read_text(errors="replace").splitlines():
        m = re.match(r".*distrobox-enter.*-n ([^ ]*)", line)
        if m:
            return m.group(1)
    return ""


def list_unmanaged_distrobox_desktops(managed_ids):
    """Distrobox-exported host desktop files not covered by any managed app id.
    Yields (path, name, container)."""
    for df in sorted(APP_DESKTOP_DIR.glob("*.desktop")):
        try:
            if "distrobox-enter" not in df.read_text(errors="replace"):
                continue
        except OSError:
            continue
        basename = df.name
        if any(mid and (mid in basename or mid == basename) for mid in managed_ids):
            continue
        yield df, desktop_entry_name(df), desktop_entry_container(df)


def cmd_latest_release(argv):
    """Resolve the latest release tag of each repo. Used by manage-updates.sh.

    Repos are fetched concurrently through the same session cache the app
    updater uses, so one call resolves a whole update scan within the
    unauthenticated rate limit. Unresolvable repos print an empty tag rather
    than failing the batch — the caller reports them as "unknown".
    """
    repos = [a for a in argv if not a.startswith("-")]
    if not repos:
        print_error("Usage: latest-release <owner/repo> [owner/repo ...]")
        return 1

    prefetch_release_json(repos)
    for repo in repos:
        print(f"{repo}\t{github_latest_tag(repo)}")
    # Marker line (never a valid repo name) so the caller can explain empty tags
    # as an exhausted quota rather than as missing releases.
    if rate_limit_reset() is not None:
        print(f"#ratelimit\t{rate_limit_reset()}")
    return 0


def cmd_list(_argv=None):
    ensure_dirs()
    found = False

    for path in list_installed_appimages():
        found = True
        slug = path.name.removesuffix(".AppImage")
        src_field = ""
        src_file = SOURCES_STATE_DIR / f"{slug}.env"
        if src_file.is_file():
            src = read_env(src_file)
            channel = " | channel=pre-release" if source_prerelease(src) else ""
            src_field = (f" | source={src.get('SOURCE_REPO', '')}{channel}"
                         f" | version={installed_version_for_source(src) or 'unknown'}")
        print(f"{slug} | type=appimage | path={path}{src_field}")

    listed_ids = []
    for f in sorted(DISTROBOX_STATE_DIR.glob("*.env")):
        found = True
        meta = read_env(f)
        listed_ids.append(meta.get("APP_ID", ""))
        args_field = f" | args={meta['APP_ARGS']}" if meta.get("APP_ARGS") else ""
        src_field = ""
        src_file = source_file_for_name(meta.get("APP_NAME", ""))
        if src_file.is_file():
            src = read_env(src_file)
            channel = " | channel=pre-release" if source_prerelease(src) else ""
            # Same notion of "installed" as check-updates, so the two can't disagree.
            src_field = (f" | source={src.get('SOURCE_REPO', '')}{channel}"
                         f" | version={installed_version_for_source(src) or 'unknown'}")
        print(f"{meta.get('APP_NAME', '')} | type=distrobox | container={meta.get('CONTAINER', '')}"
              f" | app={meta.get('APP_ID', '')} | pkg={meta.get('PACKAGE_TYPE', '')}{args_field}{src_field}")

    for df, name, container in list_unmanaged_distrobox_desktops(listed_ids):
        found = True
        print(f"{name or df.name} | type=distrobox (unmanaged) | container={container or 'unknown'} | file={df}")

    if not found:
        print_info("No managed apps found")
    return 0


# ── Interactive wizard ───────────────────────────────────────────────────────


def interactive_import_appimage_with_file(source_path, default_name=""):
    with tempfile.TemporaryDirectory() as tmp:
        extract_dir = Path(tmp) / "root"
        meta, detected = detect_appimage_name(source_path, extract_dir)
        detected = default_name or detected

        app_name = prompt_with_default("App name", detected, "Launcher name")

        slug = slugify(app_name)
        icon_status = "No icon detected"
        if meta.icon and Path(meta.icon).is_file():
            icon_status = f"Icon detected: {Path(meta.icon).name}"

        if not confirm_summary("Import AppImage", [
                f"  Source: {source_path}",
                f"  Name: {app_name}",
                f"  Destination AppImage: {APPIMAGE_DIR / (slug + '.AppImage')}",
                f"  Desktop entry: {APP_DESKTOP_DIR / (slug + '.desktop')}",
                f"  {icon_status}"]):
            print_info("Cancelled.")
            return

        execute_import_appimage(source_path, app_name, meta)


def interactive_install_distrobox_with_file(package_path):
    require_distrobox()
    container = pick_existing_distrobox_container()
    package_type = package_type_for_file(package_path)

    suggested = Path(package_path).name
    for suffix in (".deb", ".rpm", ".pkg.tar", ".pkg.tar.zst", ".pkg.tar.xz", ".pkg.tar.gz"):
        suggested = suggested.removesuffix(suffix)

    app_name = prompt_with_default("App name", suggested, "Saved app name", True)
    app_args = prompt_with_default("Launch args (optional, e.g. --disable-gpu)", "",
                                   "Leave empty for none", False)

    if not confirm_summary("Install package in Distrobox", [
            f"  Container: {container}",
            f"  Package: {package_path}",
            f"  Type: {package_type}",
            f"  App name: {app_name}",
            f"  Launch args: {app_args or 'none'}",
            "  Desktop entry: auto-detect after install"]):
        print_info("Cancelled.")
        return

    execute_install_distrobox(container, package_path, app_name, "", app_args, True)


def interactive_install_app():
    file_path = pick_file_from_downloads("Pick an app to install", "all")
    name_lower = file_path.name.lower()
    if name_lower.endswith(".appimage"):
        interactive_import_appimage_with_file(file_path)
    elif matches_mode(name_lower, "package"):
        interactive_install_distrobox_with_file(file_path)
    else:
        raise AppError(f"Unsupported file type: {file_path.name}")


def interactive_pick_channel(header="Which release channel should updates follow?"):
    """True for the pre-release channel. Cancelling reads as stable."""
    picked = gum_choose(["Stable releases only", "Include pre-releases (nightly/beta)"],
                        header=header)
    return bool(picked and picked.startswith("Include"))


def interactive_install_github():
    repo_input = prompt_with_default("GitHub repo or releases URL", "",
                                     "owner/repo or https://github.com/owner/repo")
    if not repo_input:
        return
    argv = [repo_input]
    if interactive_pick_channel():
        argv.append("--prerelease")
    cmd_install_github(argv)


def interactive_set_source(app_name):
    saved = {}
    src_file = source_file_for_name(app_name)
    if src_file.is_file():
        saved = read_env(src_file)

    repo_input = prompt_with_default("GitHub repo or releases URL", saved.get("SOURCE_REPO", ""),
                                     "owner/repo")
    if not repo_input:
        return
    version = prompt_with_default("Currently installed version tag (optional, e.g. v4.6.2)",
                                  saved.get("VERSION", ""), "Leave empty if unknown", False)
    prerelease = interactive_pick_channel()
    execute_set_source(app_name, repo_input, saved.get("ASSET_PATTERN", ""), version, prerelease)


def interactive_check_updates():
    files = list_source_files()
    if not files:
        print_info("No apps have an update source yet.")
        print_info("Install via 'Install from GitHub release', or attach one to an installed app under 'Manage installed apps'.")
        return

    _, outdated, _ = collect_update_report(files, quiet=False)

    if not outdated:
        print_success("All external apps are up to date")
        return

    labels = [f"{name} ({installed} → {latest})" for name, installed, latest in outdated]
    print_warning(f"{len(outdated)} update(s) available")

    selected = gum_choose(labels, header="Select apps to update (space to select, enter to confirm)",
                          no_limit=True)
    if selected is None:
        return
    if not selected:
        print_info("Nothing selected.")
        return

    for label in selected:
        name = outdated[labels.index(label)][0]
        try:
            execute_update_from_source(name)
        except AppError as e:
            if str(e):
                print_error(str(e))


def interactive_manage_apps():
    ensure_dirs()

    # Build unified list of installed apps: (label, type, key)
    apps = []
    for path in list_installed_appimages():
        apps.append((f"{path.name.removesuffix('.AppImage')} [AppImage]", "appimage", path))

    managed_ids = []
    for f in sorted(DISTROBOX_STATE_DIR.glob("*.env")):
        meta = read_env(f)
        managed_ids.append(meta.get("APP_ID", ""))
        apps.append((f"{meta.get('APP_NAME', '')} [Distrobox: {meta.get('CONTAINER', '')}]",
                     "distrobox", f))

    for df, name, container in list_unmanaged_distrobox_desktops(managed_ids):
        apps.append((f"{name or df.name} [Distrobox: {container or 'unknown'}] (unmanaged)",
                     "distrobox-unmanaged", df))

    if not apps:
        print_info("No installed apps found")
        return

    labels = [label for label, _, _ in apps]
    selection = gum_filter(labels, header="Manage installed apps")
    if selection is None or selection not in labels:
        print_info("Cancelled.")
        return
    _, app_type, app_key = apps[labels.index(selection)]

    # Does this app have a saved GitHub release source?
    source_file = None
    if app_type == "appimage":
        source_file = SOURCES_STATE_DIR / f"{app_key.name.removesuffix('.AppImage')}.env"
    elif app_type == "distrobox":
        source_file = SOURCES_STATE_DIR / app_key.name
    has_source = source_file is not None and source_file.is_file()

    # Pre-extract unmanaged distrobox info (used by both Update and Uninstall)
    um_name = um_container = um_app_id = ""
    if app_type == "distrobox-unmanaged":
        um_name = desktop_entry_name(app_key)
        um_container = desktop_entry_container(app_key)
        # Host desktop file is named ${container}-${app_id}, strip the prefix
        um_app_id = app_key.name.removeprefix(f"{um_container}-")

    if app_type == "distrobox-unmanaged":
        actions = ["Update (adopt)", "Uninstall", "Cancel"]
    elif has_source:
        actions = ["Update from GitHub", "Update from local file", "Switch release channel",
                   "Uninstall", "Cancel"]
    else:
        actions = ["Update from local file", "Set GitHub update source", "Uninstall", "Cancel"]

    action = gum_choose(actions) or "Cancel"

    if action == "Update (adopt)":
        # Adopt an unmanaged distrobox app: pick a package, update, save metadata
        package_path = pick_file_from_downloads("Pick the package to install", "package")
        pkg_type = package_type_for_file(package_path)
        app_name = prompt_with_default("App name", um_name, "Saved app name")

        if not confirm_summary("Adopt & update Distrobox app", [
                f"  App: {app_name}",
                f"  Container: {um_container}",
                f"  Desktop entry: {um_app_id}",
                f"  Package: {package_path}",
                f"  Type: {pkg_type}"]):
            print_info("Cancelled.")
            return

        if not install_package_in_distrobox(um_container, package_path, pkg_type):
            raise AppError("Package install failed.")
        # Skip re-export: app is already exported and may have custom flags
        save_distrobox_metadata(app_name, um_container, pkg_type, um_app_id)
        print_success("Adopted and updated Distrobox app")
        print(f"  App: {app_name}")
        print(f"  Container: {um_container}")
        print(f"  Desktop entry: {um_app_id}")

    elif action == "Update from GitHub":
        src_name = read_env(source_file).get("APP_NAME", "")
        execute_update_from_source(src_name or source_file.name.removesuffix(".env"))

    elif action == "Switch release channel":
        src = read_env(source_file)
        current = channel_label(source_prerelease(src))
        prerelease = interactive_pick_channel(
            f"Release channel for {src.get('APP_NAME', '')} (currently: {current})")
        execute_set_source(src.get("APP_NAME", ""), src.get("SOURCE_REPO", ""),
                           src.get("ASSET_PATTERN", ""), src.get("VERSION", ""), prerelease)

    elif action == "Set GitHub update source":
        if app_type == "appimage":
            target_name = app_key.name.removesuffix(".AppImage")
        else:
            target_name = read_env(app_key).get("APP_NAME", "")
        interactive_set_source(target_name)

    elif action == "Update from local file":
        if app_type == "appimage":
            current_name = app_key.name.removesuffix(".AppImage")
            new_file = pick_file_from_downloads("Pick the updated AppImage", "appimage")
            interactive_import_appimage_with_file(new_file, current_name)
        else:
            meta = read_env(app_key)
            package_path = pick_file_from_downloads("Pick the updated package", "package")
            new_type = package_type_for_file(package_path)
            type_line = "  Package type matches saved metadata"
            if new_type != meta.get("PACKAGE_TYPE"):
                type_line = f"  Warning: saved type {meta.get('PACKAGE_TYPE')}, new file looks like {new_type}"

            if not confirm_summary("Update Distrobox app", [
                    f"  App: {meta.get('APP_NAME', '')}",
                    f"  Container: {meta.get('CONTAINER', '')}",
                    f"  Desktop entry: {meta.get('APP_ID', '')}",
                    f"  Launch args: {meta.get('APP_ARGS') or 'none'}",
                    f"  New package: {package_path}",
                    type_line]):
                print_info("Cancelled.")
                return
            execute_update_distrobox(meta.get("APP_NAME", ""), package_path)

    elif action == "Uninstall":
        if app_type == "appimage":
            if not confirm_summary("Remove AppImage", [f"  AppImage: {app_key}"]):
                print_info("Cancelled.")
                return
            execute_remove_appimage(app_key)
        elif app_type == "distrobox-unmanaged":
            if not confirm_summary("Remove Distrobox app (unmanaged)", [
                    f"  App: {um_name}",
                    f"  Container: {um_container}",
                    f"  Desktop file: {app_key}"]):
                print_info("Cancelled.")
                return
            if um_container:
                print_info(f"Removing exported app '{um_app_id}' from container '{um_container}'...")
                subprocess.run(["distrobox-enter", "--name", um_container, "--no-tty", "--",
                                "distrobox-export", "--delete", "--app", um_app_id],
                               stderr=subprocess.DEVNULL, check=False)
            app_key.unlink(missing_ok=True)
            refresh_desktop_db()
            print_success("Removed Distrobox app")
            print(f"  App: {um_name}")
            print(f"  Container: {um_container}")
        else:
            meta = read_env(app_key)
            if not confirm_summary("Remove Distrobox app", [
                    f"  App: {meta.get('APP_NAME', '')}",
                    f"  Container: {meta.get('CONTAINER', '')}",
                    f"  Desktop entry: {meta.get('APP_ID', '')}"]):
                print_info("Cancelled.")
                return
            execute_remove_distrobox(app_key)

    else:
        print_info("Cancelled.")


def main_menu():
    while True:
        action = gum_choose([
            "Install app (local file)",
            "Install from GitHub release",
            "Manage installed apps",
            "Check for updates",
            "Cancel",
        ]) or "Cancel"

        handlers = {
            "Install app (local file)": interactive_install_app,
            "Install from GitHub release": interactive_install_github,
            "Manage installed apps": interactive_manage_apps,
            "Check for updates": interactive_check_updates,
        }
        handler = handlers.get(action)
        if handler is None:
            print_info("Cancelled.")
            return 0
        try:
            handler()
        except Cancelled:
            pass
        except AppError as e:
            if str(e):
                print_error(str(e))


# ── Entry point ──────────────────────────────────────────────────────────────

COMMANDS = {
    "import-appimage": cmd_import_appimage,
    "remove-appimage": cmd_remove_appimage,
    "install-distrobox": cmd_install_distrobox,
    "update-distrobox": cmd_update_distrobox,
    "install-github": cmd_install_github,
    "set-source": cmd_set_source,
    "check-updates": cmd_check_updates,
    "update": cmd_update_app,
    "list": cmd_list,
    "latest-release": cmd_latest_release,
}


def main(argv):
    if not argv:
        return main_menu()
    cmd, rest = argv[0], argv[1:]
    if cmd in ("help", "--help", "-h"):
        print(USAGE)
        return 0
    if cmd == "check-updates" and rest[:1] == ["--interactive"]:
        interactive_check_updates()
        return 0
    handler = COMMANDS.get(cmd)
    if handler is None:
        return main_menu()
    return handler(rest) or 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Cancelled:
        print_info("Cancelled.")
        sys.exit(0)
    except AppError as e:
        if str(e):
            print_error(str(e))
        sys.exit(1)
    except KeyboardInterrupt:
        # manage.sh's interrupt trap already prints "Interrupted." when it owns
        # the tree (marker exported by install_interrupt_trap) — stay quiet then.
        if not os.environ.get("_INTERRUPT_TRAP_OWNER"):
            print()
            print_warning("Interrupted.")
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(0)
