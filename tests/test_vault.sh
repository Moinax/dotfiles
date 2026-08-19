#!/usr/bin/env bash
# The round trip a vault has to survive: a directory goes in, comes back byte
# for byte, and is genuinely unreadable in between.
#
# The two guards worth a test are the ones that cost data if they slip: `open`
# must refuse to mount over a directory that still holds files, and `decrypt`
# must not drop the ciphertext until everything has been moved back out.
#
# Run: bash tests/test_vault.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="$SCRIPT_DIR/../home/dot_local/bin/executable_vault"

command -v gocryptfs >/dev/null || { echo "SKIP: gocryptfs is not installed"; exit 0; }

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

stage=$(mktemp -d)
# The registry lives under XDG_CONFIG_HOME, so pointing it at the stage is all
# it takes to keep the real one out of this.
export XDG_CONFIG_HOME="$stage/config"
export VAULT_PASSFILE="$stage/pw"
echo "correct horse battery staple" > "$VAULT_PASSFILE"

photos="$stage/Photos"
mkdir -p "$photos/trip"
echo "a cat" > "$photos/cat.txt"
echo "hidden" > "$photos/.exif"
echo "a beach" > "$photos/trip/beach.txt"

# VAULT_PASSFILE short-circuits both password paths, so these runs never care
# whether the test itself has a terminal.
echo "encrypt"
bash "$VAULT" encrypt "$photos" >/dev/null 2>&1
check "encrypt succeeds" "0" "$?"
check "only the padlock marker is left" ".directory" "$(ls -A "$photos")"
check "the icon KIO will read" "Icon=folder-locked" \
      "$(grep -h "^Icon=" "$photos/.directory")"
check "and Type, without which KIO ignores the file" "Type=Directory" \
      "$(grep -h "^Type=" "$photos/.directory")"
check "the ciphertext sits beside it" "yes" \
      "$([ -d "$stage/.Photos.gocryptfs" ] && echo yes || echo no)"
check "no plaintext name survives" "0" \
      "$(grep -rl "cat.txt\|beach" "$stage/.Photos.gocryptfs" 2>/dev/null | wc -l)"
check "listed as closed" "closed" "$(bash "$VAULT" list | awk '{print $1}')"

echo "open"
bash "$VAULT" open "$photos" >/dev/null 2>&1
check "open succeeds" "0" "$?"
check "listed as open" "open" "$(bash "$VAULT" list | awk '{print $1}')"
check "file content is back" "a cat" "$(cat "$photos/cat.txt" 2>/dev/null)"
check "dotfiles came along" "hidden" "$(cat "$photos/.exif" 2>/dev/null)"
check "so did subdirectories" "a beach" "$(cat "$photos/trip/beach.txt" 2>/dev/null)"

echo "close"
bash "$VAULT" close "$photos" >/dev/null 2>&1
check "close succeeds" "0" "$?"
check "the plaintext is gone again" ".directory" "$(ls -A "$photos")"

echo "open refuses to shadow files"
echo "stray" > "$photos/stray.txt"
bash "$VAULT" open "$photos" >/dev/null 2>&1
check "open on a non-empty directory fails" "1" "$?"
check "and left the stray file alone" "stray" "$(cat "$photos/stray.txt")"
rm -f "$photos/stray.txt"

echo "wrong password"
VAULT_PASSFILE="$stage/wrong" bash -c 'echo nope > "$1"' _ "$stage/wrong"
VAULT_PASSFILE="$stage/wrong" bash "$VAULT" open "$photos" >/dev/null 2>&1
check "a wrong password does not mount" "1" "$?"
# The retry loop must not spin on a passfile: same file, same wrong password,
# forever. A hang here is the failure, so the check is that we got this far.
check "and gave up rather than retrying the same file" "closed" \
      "$(bash "$VAULT" list | awk -v d="$photos" '$2 == d {print $1}')"

echo "auto-lock"
VAULT_IDLE=3s bash "$VAULT" open "$photos" >/dev/null 2>&1
check "opens with an idle timeout set" "a cat" "$(cat "$photos/cat.txt" 2>/dev/null)"
for _ in $(seq 20); do mountpoint -q "$photos" || break; sleep 1; done
check "and locks itself once left alone" ".directory" "$(ls -A "$photos")"

echo "key"
key=$(bash "$VAULT" key "$photos" 2>/dev/null)
check "prints a 256-bit master key" "64" "${#key}"
check "and it is hex" "yes" \
      "$(printf '%s' "$key" | grep -qE '^[0-9a-f]{64}$' && echo yes || echo no)"
# The point of the key is that it opens the vault with neither the password nor
# the config file, so that is what gets checked — on a copy, with both removed.
cp -a "$stage/.Photos.gocryptfs" "$stage/orphan"
rm -f "$stage/orphan/gocryptfs.conf"
mkdir -p "$stage/rescue"
printf '%s' "$key" | gocryptfs -q -masterkey=stdin "$stage/orphan" "$stage/rescue" 2>/dev/null
check "and recovers a vault stripped of its config" "a cat" \
      "$(cat "$stage/rescue/cat.txt" 2>/dev/null)"
mountpoint -q "$stage/rescue" && fusermount -u "$stage/rescue"

echo "toggle, the one Dolphin calls"
docs="$stage/Docs"
mkdir -p "$docs"
echo "a note" > "$docs/note.txt"
# Answering the confirmation on stdin is the terminal path; VAULT_GUI is unset
# throughout this file, so nothing here can reach for kdialog.
echo y | bash "$VAULT" toggle "$docs" >/dev/null 2>&1
check "toggle encrypts a plain directory" "closed" \
      "$(bash "$VAULT" list | awk -v d="$docs" '$2 == d {print $1}')"
bash "$VAULT" toggle "$docs" >/dev/null 2>&1
check "toggle opens a closed vault" "a note" "$(cat "$docs/note.txt" 2>/dev/null)"
bash "$VAULT" toggle "$docs" >/dev/null 2>&1
check "toggle closes an open one" ".directory" "$(ls -A "$docs")"
echo n | bash "$VAULT" toggle "$stage/Plain" >/dev/null 2>&1
check "toggle on a missing directory fails" "1" "$?"

echo "decrypt, which asks first"
bash "$VAULT" decrypt "$photos" < /dev/null >/dev/null 2>&1
check "an unanswered confirmation decrypts nothing" ".directory" "$(ls -A "$photos")"

echo y | bash "$VAULT" decrypt "$photos" >/dev/null 2>&1
check "decrypt succeeds" "0" "$?"
check "content is plain again" "a cat" "$(cat "$photos/cat.txt")"
check "and so are subdirectories" "a beach" "$(cat "$photos/trip/beach.txt")"
check "the padlock marker is gone too" "0" \
      "$([ -e "$photos/.directory" ] && echo 1 || echo 0)"
check "the ciphertext is gone" "no" \
      "$([ -d "$stage/.Photos.gocryptfs" ] && echo yes || echo no)"
# The Docs vault from the toggle section is still registered, and should be:
# decrypting one vault must not forget the others.
check "the registry drops it" "0" \
      "$(grep -cxF "$photos" "$XDG_CONFIG_HOME/vault/vaults" 2>/dev/null)"
check "and keeps the other one" "1" \
      "$(grep -cxF "$docs" "$XDG_CONFIG_HOME/vault/vaults" 2>/dev/null)"

mountpoint -q "$photos" && fusermount -u "$photos"
rm -rf "$stage"

if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$failures check(s) failed"
    exit 1
fi
