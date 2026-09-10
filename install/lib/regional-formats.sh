#!/bin/bash
# Belgian date, currency and paper formats on an otherwise English machine.
#
# The interface stays in English — `LANG` and `LC_MESSAGES` are left alone, so
# every tool keeps printing the messages this repo's own code matches on
# (arch.sh pins `LC_ALL=C` around pacman for exactly that reason). Only the
# format categories move, and only the four that carry a regional convention:
# LC_TIME, LC_MONETARY, LC_MEASUREMENT, LC_PAPER.
#
# **LC_NUMERIC stays American on purpose.** A comma decimal separator is read by
# printf, awk, sort -g and every script that formats a number, so flipping it
# turns "3.14" into "3,14" in output that other code then fails to parse. The
# gain would be cosmetic; the breakage is not.
#
# Two steps here need root — writing /etc/locale.conf and generating the locale
# — which is why this is a lib rather than a chezmoi file: an apply must never
# carry a sudo prompt. `dots setup` runs it once (setup_regional_formats in
# install/installer.sh) and `dots update` offers it to a machine that is missing
# it (reconcile_regional_formats in tools/sync-machine.sh).
#
# The browser half is deliberately NOT here: Firefox reads its formats from its
# own application locale and ignores LC_TIME entirely (verified against
# LC_TIME, LC_ALL, intl.regional_prefs.use_os_locale, intl.accept_languages and
# intl.date_time.pattern_override — none of them moved a `<input type="date">`
# off mm/dd/yyyy). It needs a per-profile pref, which needs no root, so it lives
# in home/run_configure-firefox-locale.sh.tmpl.
#
# Requires common.sh (print helpers, track_warning, command_exists) to be sourced.

REGIONAL_LOCALE=fr_BE.UTF-8
REGIONAL_LOCALE_LINE="fr_BE.UTF-8 UTF-8"
REGIONAL_CATEGORIES=(LC_TIME LC_MONETARY LC_MEASUREMENT LC_PAPER)
REGIONAL_LOCALE_CONF=/etc/locale.conf
REGIONAL_LOCALE_GEN=/etc/locale.gen

# glibc answers only for locales that were generated: setting LC_TIME to one
# that was not silently falls back to POSIX, which formats dates *worse* than
# the American default it replaced. Checked by name because `locale -a`
# normalises the suffix (fr_BE.utf8, no dash).
regional_locale_generated() {
    locale -a 2>/dev/null | grep -qix "fr_BE.utf8"
}

regional_categories_set() {
    local category
    for category in "${REGIONAL_CATEGORIES[@]}"; do
        grep -qx "$category=$REGIONAL_LOCALE" "$REGIONAL_LOCALE_CONF" 2>/dev/null || return 1
    done
}

# The language pack is what makes fr-BE resolvable as an application locale:
# without it Firefox falls back to en-US and the profile pref does nothing,
# which is the failure this whole file exists to prevent. Only checked where
# Firefox is installed at all.
regional_firefox_langpack_missing() {
    command_exists firefox && ! pacman -Qq firefox-i18n-fr >/dev/null 2>&1
}

regional_formats_needs_setup() {
    ! regional_locale_generated || ! regional_categories_set || regional_firefox_langpack_missing
}

apply_regional_formats() {
    if ! regional_locale_generated; then
        print_info "Generating $REGIONAL_LOCALE"
        # Appended rather than uncommented: the CachyOS installer appends its own
        # line the same way, and an append is idempotent against both layouts.
        if ! grep -qxF "$REGIONAL_LOCALE_LINE" "$REGIONAL_LOCALE_GEN" 2>/dev/null; then
            echo "$REGIONAL_LOCALE_LINE" | sudo tee -a "$REGIONAL_LOCALE_GEN" >/dev/null || {
                track_warning "Could not add $REGIONAL_LOCALE to $REGIONAL_LOCALE_GEN"
                return 1
            }
        fi
        sudo locale-gen >/dev/null || {
            track_warning "locale-gen failed — regional formats left as they were"
            return 1
        }
    fi

    if ! regional_categories_set; then
        print_info "Pointing date, currency, measurement and paper formats at $REGIONAL_LOCALE"
        local category
        for category in "${REGIONAL_CATEGORIES[@]}"; do
            # Rewrite in place when the key exists, append when it does not: a
            # machine whose installer wrote no LC_TIME at all still ends up with
            # one, and neither branch can leave the key twice.
            if grep -q "^$category=" "$REGIONAL_LOCALE_CONF" 2>/dev/null; then
                sudo sed -i "s|^$category=.*|$category=$REGIONAL_LOCALE|" "$REGIONAL_LOCALE_CONF"
            else
                echo "$category=$REGIONAL_LOCALE" | sudo tee -a "$REGIONAL_LOCALE_CONF" >/dev/null
            fi || {
                track_warning "Could not write $category to $REGIONAL_LOCALE_CONF"
                return 1
            }
        done
        # PAM reads locale.conf when a session opens, so the running one keeps the
        # old values — worth saying, since the symptom of not knowing is thinking
        # the whole thing failed.
        print_info "Applies to sessions opened from now on — log out and back in for the current one"
    fi

    if regional_firefox_langpack_missing; then
        print_info "Installing the French language pack Firefox needs to resolve fr-BE"
        sudo pacman -S --needed --noconfirm firefox-i18n-fr >/dev/null 2>&1 ||
            track_warning "Could not install firefox-i18n-fr — Firefox will keep formatting dates as mm/dd/yyyy"
    fi

    print_success "Regional formats set to $REGIONAL_LOCALE"
}
