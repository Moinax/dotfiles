---
description: How the lock screen and the login greeter come to share /var/lib/wallpaper/current, which two steps need root and why both dots setup and dots update own them, and the nested greeter key that reads as success while repointing nothing.
paths:
  - install/lib/login-wallpaper.sh
  - home/dot_local/bin/executable_wallpaper-picker.sh
  - home/dot_config/hypr/hyprlock.conf.tmpl
  - home/dot_config/systemd/user/awww-init.service
---

# One file behind two screens

The lock screen and the login greeter share `/var/lib/wallpaper/current`.

The Plasma Login Manager greeter runs as the `plasmalogin` system user and
`$HOME` is 0700, so it can never read `~/Wallpapers` — that is why KDE's own
Login Screen KCM copies the bytes out through a KAuth helper it only exposes
behind the GUI. We copy too, but into a user-owned directory outside `$HOME`,
which is what lets `wallpaper-picker apply` republish on every pick with no root
at all: the greeter config names a path that never changes. hyprlock reads that
same path, so the two screens agree because it is one file, not because two
configs match.

**Deliberately extension-less.** Both readers sniff content (hyprgraphics links
libmagic, Qt uses QMimeDatabase), so a fixed `current.jpg` would lie the first
time a `.png` is picked.

## The two privileged steps, and why setup cannot be their only owner

Creating that directory user-owned and pointing the greeter at it are the only
steps that need root, so they live here and **both `dots setup` and `dots update`
call them** (`reconcile_login_wallpaper`).

That split exists because of a specific failure: the feature shipped as an
installer step plus a `hyprlock.conf` naming the file, and setup is not re-run, so
every machine that *already existed* pulled the dotfile half and got a **black
lock screen**. Nothing reported it, because every piece involved was behaving as
designed. The general form of that lesson, and the six other installer-only steps
that still have the same shape, are in `sync-machine.md`.

`login_wallpaper_needs_setup` asks only about those two privileged steps. A
published file that is merely *missing* is deliberately not a trigger: with a
writable directory the picker republishes at the next pick and `awww-init` seeds
it at session start, both with no privilege, so prompting for a password there
would buy nothing.

Picking a wallpaper cannot repair it either — `publish_wallpaper` notifies ("the
lock and login screens keep the old one") and lets the pick succeed, since the
desktop is already set by then. Do not move the creation into post-apply, which
would put a sudo prompt in every `chezmoi apply`.

## The greeter key is nested, and the flat one is read by nothing

`Image` under **`[Greeter][Wallpaper][org.kde.image][General]`**, written as a
`file://` URL — matching what KDE's Login Screen KCM writes through its KAuth
helper, the only reference we can check ourselves against.

The first version of the installer step wrote those last three groups at the *top*
level and printed success; `kreadconfig6` on that path returns empty on a
configured machine, so it repointed nothing and would have kept the stock KDE
wallpaper even after a full `dots setup`. That is why
`login_wallpaper_greeter_image` exists as a reader and not just a writer: the
detection and the write share one group path, so they cannot drift apart again.

Everything that writes the published file goes through `wallpaper-picker.sh
publish` — the installer's seed and `awww-init.service` included, the latter
because seeding the desktop around the picker is exactly what left a fresh machine
with a black lock screen.

## Two things this does not buy

- hyprlock can only be *dressed* like the greeter, never be it: a lock screen must
  hold the compositor's `ext-session-lock-v1` grab inside the running session,
  while the greeter is another user's session on another VT.
- Opening System Settings → Login Screen rewrites `/etc/plasmalogin.conf` with the
  KCM's own copied path. The next `dots update` sees the mismatch and offers to put
  it back, so this heals itself rather than needing the installer step re-run by
  hand.
