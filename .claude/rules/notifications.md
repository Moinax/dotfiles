---
description: How to make a notification clickable — the generic swaync hook exists already, so a new sender adds three flags and no hook of its own.
paths:
  - home/dot_config/swaync/config.json
  - home/dot_local/bin/executable_*
---

# A clickable notification needs three pieces

`notify-send -A` alone is not one of them: its `--action` wait dies with the
popup, so a click once the notification is parked in the swaync control center
lands nowhere.

The three pieces already exist as a generic mechanism, so a new clickable
notification is **sender-side only**:

- `-A default=…` — without an action, swaync ignores clicks entirely
- `-c x-open`
- `-h string:x-open-path:<file>`

The `open-on-click` hook in `swaync/config.json` (`run-on: "action"`, matched on
that category) runs `notify-open`, which unwraps the hint and `xdg-open`s it.

**Never clone the hook or the opener for a new sender.** A click target that
isn't "open this file" is the only reason to add a hook.

swaync exports hints to scripts as `SWAYNC_HINT_<KEY>`: uppercased,
dashes→underscores, string values wrapped in literal single quotes.

## Two non-candidates, not to re-audit

- Kitty-forwarded notifications (the "Claude Code" needs-attention ones) already
  focus their window on click; kitty owns that action.
- **hyprshot must never be notified around directly** — it backgrounds its grab
  and returns before the PNG is written, which is why `screenshot.sh` only
  notifies from hyprshot's `-- command` callback. A notify with the half-written
  file as icon makes swaync drop the notification wholesale.
