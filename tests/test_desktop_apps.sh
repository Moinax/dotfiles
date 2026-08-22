#!/usr/bin/env bash
# What the freedesktop crawl behind both pickers has to get right.
#
# desktop-apps is now shared: the Browser picker (Mod+Alt+B) and the Chat picker
# (Mod+Alt+C) render its output, and `chats` uses it to decide which of the four
# apps is installed at all. A shift in its tab-separated columns is therefore not
# a display bug in one menu — it silently changes what `chats` launches.
#
# Run: bash tests/test_desktop_apps.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS="$SCRIPT_DIR/../home/dot_local/bin/executable_desktop-apps"

failures=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
    else
        echo "  FAIL $label: expected '$expected', got '$actual'"
        failures=$((failures + 1))
    fi
}

entry() {
    local file="$1"; shift
    printf '[Desktop Entry]\nType=Application\n' > "$file"
    printf '%s\n' "$@" >> "$file"
}

fixtures=$(mktemp -d)
trap 'rm -rf "$fixtures"' EXIT

entry "$fixtures/zebra.desktop"   'Name=Zebra'     'Icon=zebra'      'Categories=Network;WebBrowser;'
# Icon before Name, and an absolute icon path: the awk pass must not care about
# field order, and must carry the path through untouched.
entry "$fixtures/helix.desktop"   'Icon=/opt/helix/icon.png' 'Name=helix' 'Categories=WebBrowser;'
# No Name= at all — the desktop id has to stand in, or the row loses a column.
entry "$fixtures/nameless.desktop" 'Icon=nameless' 'Categories=WebBrowser;'
# Same display name as zebra.desktop: one of the two survives, and which one is
# decided by the sort of the file *path* — 'zebra-beta.desktop' sorts before
# 'zebra.desktop' because '-' precedes '.'. Pinned here because it is the only
# thing that makes the dedupe deterministic, and it is not obvious from the code.
entry "$fixtures/zebra-beta.desktop" 'Name=Zebra'  'Icon=beta'       'Categories=WebBrowser;'
entry "$fixtures/hidden.desktop"  'Name=Hidden'    'NoDisplay=true'  'Categories=WebBrowser;'
entry "$fixtures/chatty.desktop"  'Name=Chatty'    'Icon=chatty'     'Categories=Network;InstantMessaging;'
# Trailing-semicolon-less Categories, which some entries ship.
entry "$fixtures/tailless.desktop" 'Name=Tailless' 'Icon=tailless'   'Categories=Network;InstantMessaging'

# `bash "$APPS"` and not the path alone: the source file carries chezmoi's
# executable_ prefix rather than the mode bit, which only the apply confers.
run() { DESKTOP_APP_DIRS="$fixtures" bash "$APPS" "$@"; }

echo "desktop-apps list"

check "browsers, deduped and capitalized" \
    "$(printf 'helix\tHelix\t/opt/helix/icon.png\nnameless\tNameless\tnameless\nzebra-beta\tZebra\tbeta')" \
    "$(run list WebBrowser)"

check "hidden entry is skipped" \
    "0" \
    "$(run list WebBrowser | grep -c Hidden || true)"

check "chat apps, with and without a trailing semicolon" \
    "$(printf 'chatty\tChatty\tchatty\ntailless\tTailless\ttailless')" \
    "$(run list InstantMessaging)"

# The whole point of anchoring the category: a prefix must not match, or a typo
# comes back as a plausible-looking wrong list instead of nothing.
check "category is a whole field, not a prefix" \
    "" \
    "$(run list Web)"

check "empty scan exits 0, so a picker can render its own empty view" \
    "0" \
    "$(run list Nothing >/dev/null 2>&1; echo $?)"

echo "desktop-apps usage"

check "no subcommand is a usage error" \
    "2" \
    "$(run >/dev/null 2>&1; echo $?)"

check "launch without an id is an error" \
    "1" \
    "$(run launch >/dev/null 2>&1; echo $?)"

echo
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$failures check(s) failed"
fi
exit "$failures"
