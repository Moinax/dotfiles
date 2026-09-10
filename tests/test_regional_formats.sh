#!/usr/bin/env bash
# What makes a machine count as needing the Belgian format setup.
#
# `regional_formats_needs_setup` gates a sudo prompt in `dots update`, so it has
# to be exact in both directions: a false positive asks for a password on every
# run of a machine that is already done, and a false negative leaves a machine
# on mm/dd/yyyy forever, since setup is never re-run.
#
# Three inputs decide it, and each one alone must be enough to trigger:
#
#   - the locale is not generated (setting LC_TIME to it would fall back to
#     POSIX, which is worse than the American default it replaces)
#   - a category in locale.conf still names another locale, or is missing
#     entirely — a machine whose installer wrote no LC_TIME at all
#   - Firefox is installed without the language pack that makes fr-BE
#     resolvable, which is what the profile pref needs to have any effect
#
# LC_NUMERIC must never be in the set: a comma decimal separator breaks printf,
# awk and sort -g. That is asserted here so a later edit cannot add it quietly.
#
# Run: bash tests/test_regional_formats.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../install/lib/regional-formats.sh"

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

mkdir -p "$SCRIPT_DIR/../.scratch"
stage=$(mktemp -d "$SCRIPT_DIR/../.scratch/regional-formats.XXXXXX")
trap 'rm -rf "$stage"' EXIT

# The lib reads three facts off the machine. Each stub answers one, so a case
# can move exactly one of them and leave the rest satisfied.
needs_setup() {
    local generated="$1" langpack="$2" conf="$3"
    # The stubs read their answers from variables, never from positional
    # parameters: inside a function $2 is that function's own argument, so
    # `locale -a` would read "-a" instead of the case being staged.
    bash -c '
        source "$1"
        answer_generated="$2" answer_langpack="$3" REGIONAL_LOCALE_CONF="$4"
        locale() { [ "$answer_generated" = yes ] && echo fr_BE.utf8; }
        pacman() { [ "$answer_langpack" = yes ]; }
        command_exists() { [ "$1" = firefox ]; }
        regional_formats_needs_setup && echo yes || echo no
    ' _ "$LIB" "$generated" "$langpack" "$conf"
}

write_conf() {
    printf '%s\n' "$@" > "$stage/locale.conf"
    echo "$stage/locale.conf"
}

complete=$(write_conf LANG=en_US.UTF-8 LC_NUMERIC=en_US.UTF-8 \
    LC_TIME=fr_BE.UTF-8 LC_MONETARY=fr_BE.UTF-8 LC_MEASUREMENT=fr_BE.UTF-8 LC_PAPER=fr_BE.UTF-8)

echo "a machine already converted needs nothing"
check "all four categories, locale generated, langpack present" no "$(needs_setup yes yes "$complete")"

echo "each missing piece triggers on its own"
check "locale not generated" yes "$(needs_setup no yes "$complete")"
check "Firefox without the language pack" yes "$(needs_setup yes no "$complete")"

partial=$(write_conf LANG=en_US.UTF-8 LC_TIME=fr_BE.UTF-8 LC_MONETARY=en_US.UTF-8 \
    LC_MEASUREMENT=fr_BE.UTF-8 LC_PAPER=fr_BE.UTF-8)
check "one category still American" yes "$(needs_setup yes yes "$partial")"

absent=$(write_conf LANG=en_US.UTF-8)
check "categories never written at all" yes "$(needs_setup yes yes "$absent")"

echo "the number format is deliberately left alone"
categories=$(bash -c 'source "$1"; echo "${REGIONAL_CATEGORIES[@]}"' _ "$LIB")
check "LC_NUMERIC stays out of the set" "" "$(echo " $categories " | grep -o ' LC_NUMERIC ')"
check "the four regional categories" "LC_TIME LC_MONETARY LC_MEASUREMENT LC_PAPER" "$categories"

echo "a failed category write stops setup, even when later writes would succeed"
for mode in replace append; do
    conf=$(write_conf LANG=en_US.UTF-8 LC_NUMERIC=en_US.UTF-8)
    if [ "$mode" = replace ]; then
        printf '%s\n' LC_TIME=en_US.UTF-8 >> "$conf"
    fi
    result=$(bash -c '
        set -e
        source "$1"
        REGIONAL_LOCALE_CONF="$2"
        regional_locale_generated() { return 0; }
        regional_firefox_langpack_missing() { return 1; }
        print_info() { :; }
        print_success() { echo unexpected-success; }
        track_warning() { echo warning; }
        # Never execute sudo: simulate only the first category failing.
        sudo() {
            if [ "$1" = sed ]; then
                [[ "$3" != *LC_TIME* ]] || return 1
                command "$@"
            else
                local line
                IFS= read -r line
                [[ "$line" != LC_TIME=* ]] || return 1
                printf "%s\n" "$line" | command "$@"
            fi
        }
        apply_regional_formats && echo status=0 || echo status=$?
    ' _ "$LIB" "$conf")
    check "$mode failure is reported" $'warning\nstatus=1' "$result"
    check "$mode failure stops subsequent writes" "" "$(grep '^LC_PAPER=' "$conf")"
done

echo "Firefox profiles created after the first apply are configured on the next"
firefox_source="$stage/source"
firefox_destination="$stage/destination"
mkdir -p "$firefox_source" "$firefox_destination"
# Render the browser-enabled branch into an isolated chezmoi source. Redirect
# only Firefox's root; no real profile or user configuration is touched.
sed '1d;$d;s|^FIREFOX_ROOT=.*|FIREFOX_ROOT="$TEST_FIREFOX_ROOT"|' \
    "$SCRIPT_DIR/../home/run_configure-firefox-locale.sh.tmpl" \
    > "$firefox_source/run_configure-firefox-locale.sh"
export TEST_FIREFOX_ROOT="$stage/firefox"
apply_firefox() {
    chezmoi --config /dev/null --config-format toml --source "$firefox_source" \
        --destination "$firefox_destination" --persistent-state "$stage/chezmoi-state.boltdb" \
        apply >/dev/null
}
apply_firefox || failures=$((failures + 1))
mkdir -p "$TEST_FIREFOX_ROOT/new.Profile 1"
printf '%s\n' '[Profile0]' 'IsRelative=1' 'Path=new.Profile 1' > "$TEST_FIREFOX_ROOT/profiles.ini"
apply_firefox || failures=$((failures + 1))
pref='user_pref("intl.locale.requested", "fr-BE");'
user_js="$TEST_FIREFOX_ROOT/new.Profile 1/user.js"
check "new profile receives the preference" "$pref" "$(grep '^user_pref' "$user_js")"
apply_firefox || failures=$((failures + 1))
check "repeated apply keeps one preference" 1 "$(grep -c '^user_pref' "$user_js")"

echo ""
if [ "$failures" -eq 0 ]; then
    echo "All checks passed"
else
    echo "$failures check(s) failed"
fi
exit $((failures > 0))
