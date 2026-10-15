#!/usr/bin/env python3

# Wayland idle inhibitor — creates an idle inhibitor surface that prevents
# the compositor from reporting the session as idle (pauses hypridle/swayidle
# timeouts). Runs until SIGINT/SIGTERM. Requires pywayland.
# Based on https://github.com/stwa/wayland-idle-inhibitor (WTFPL license)

# The exec bit comes from chezmoi's executable_ prefix at apply time, so the
# source file here is (and stays) mode 644 like every other script in this dir.
# ruff: noqa: EXE001

import os
import sys
from dataclasses import dataclass
from pathlib import Path
from select import select
from signal import SIGINT, SIGTERM, signal

from pywayland.client.display import Display

try:
    # PyWayland 0.4.19 generates one flat module per protocol.
    from pywayland.protocol.idle_inhibit_unstable_v1 import ZwpIdleInhibitManagerV1
    from pywayland.protocol.wayland import WlCompositor, WlRegistryProxy, WlSurface
except ImportError:
    # PyWayland <= 0.4.18 generated a package containing one module per interface.
    from pywayland.protocol.idle_inhibit_unstable_v1.zwp_idle_inhibit_manager_v1 import (
        ZwpIdleInhibitManagerV1,
    )
    from pywayland.protocol.wayland.wl_compositor import WlCompositor
    from pywayland.protocol.wayland.wl_registry import WlRegistryProxy
    from pywayland.protocol.wayland.wl_surface import WlSurface


@dataclass
class GlobalRegistry:
    surface: WlSurface | None = None
    inhibit_manager: ZwpIdleInhibitManagerV1 | None = None


def handle_registry_global(
    wl_registry: WlRegistryProxy, id_num: int, iface_name: str, version: int
) -> None:
    global_registry: GlobalRegistry = wl_registry.user_data or GlobalRegistry()

    if iface_name == "wl_compositor":
        compositor = wl_registry.bind(id_num, WlCompositor, version)
        global_registry.surface = compositor.create_surface()
    elif iface_name == "zwp_idle_inhibit_manager_v1":
        global_registry.inhibit_manager = wl_registry.bind(
            id_num, ZwpIdleInhibitManagerV1, version
        )


def main() -> None:
    # Exiting from the handler rather than flagging an Event: the wait below is a
    # select(), and PEP 475 runs the handler when it is interrupted, so SystemExit
    # propagates out of it and the `finally` runs. A flag would need a wakeup fd
    # to break the select, which is three more moving parts for the same effect.
    signal(SIGINT, lambda _, __: sys.exit(0))
    signal(SIGTERM, lambda _, __: sys.exit(0))

    global_registry = GlobalRegistry()

    display = Display()
    display.connect()

    registry = display.get_registry()
    registry.user_data = global_registry
    registry.dispatcher["global"] = handle_registry_global

    def shutdown() -> None:
        display.dispatch()
        display.roundtrip()
        display.disconnect()

    display.dispatch()
    display.roundtrip()

    if global_registry.surface is None or global_registry.inhibit_manager is None:
        print("Wayland does not support idle_inhibit_unstable_v1 protocol.")
        shutdown()
        sys.exit(1)

    # Nothing keeps the returned proxy: pywayland never destroys objects on
    # garbage collection, so the inhibitor lives as long as the connection.
    global_registry.inhibit_manager.create_inhibitor(global_registry.surface)

    display.dispatch()
    display.roundtrip()

    # Owning the state file is what keeps the waybar indicator honest. This write
    # is also the readiness signal the toggle waits for — the inhibition exists
    # from here on — and the `finally` below flips it back however this process
    # ends: SIGTERM, an unhandled exception, or the compositor dropping us.
    # SIGKILL is the one death that still leaves a stale "on" behind.
    state_file = os.environ.get("CAFFEINE_STATE_FILE")
    if state_file:
        Path(state_file).write_text("on\n")

    # Keep draining the connection. Sleeping on the signal instead left the
    # socket unread for as long as caffeine was on, and a client that never reads
    # is one the compositor may drop — which is how caffeine expired silently
    # mid-session on 2026-10-15, hours after the toggle, with waybar still
    # showing it on. A dispatch error now ends the process, writes "off", and
    # leaves a traceback in the log the toggle keeps.
    #
    # The wait is select() and not `display.dispatch(block=True)` on its own,
    # because libwayland retries its own poll() on EINTR: a dispatch blocked on
    # an idle socket never returns to let Python run the signal handler, so
    # SIGTERM left the process up and the toggle's `wait` hung on it. Dispatch
    # still blocks, which is what reads the socket — `block=False` only drains
    # the already-decoded queue and would leave the fd unread, the exact bug
    # above. Nothing needs destroying on the way out: the inhibitor dies with
    # the connection.
    display_fd = display.get_fd()
    try:
        while True:
            select([display_fd], [], [])
            display.dispatch(block=True)
    finally:
        if state_file:
            Path(state_file).write_text("off\n")


if __name__ == "__main__":
    main()
