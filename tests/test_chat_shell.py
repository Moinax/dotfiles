#!/usr/bin/env python3
"""The two things the chat shell gets wrong silently.

The badge has to land inside the icon at any screen scale: sized off the
pixmap's physical width, it was drawn entirely outside the canvas on a scaled
screen — painted every time, visible never. And the label is assembled rather
than passed through: the count is parsed out of the site's title and rendered
once, from the badge when the page publishes one.

Run: python3 tests/test_chat_shell.py
"""

import os
import sys
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent
                      / "home" / "dot_local" / "lib"))

import chat_shell
from chat_shell import ChatApp, paint_badge, parse_title, window_title
from PyQt6.QtGui import QColor, QPixmap
from PyQt6.QtWebEngineCore import QWebEnginePage
from PyQt6.QtWebEngineWidgets import QWebEngineView
from PyQt6.QtWidgets import QApplication


def red_pixels(image):
    return sum(
        1
        for y in range(image.height())
        for x in range(image.width())
        if (c := QColor(image.pixel(x, y))).red() > 150 and c.green() < 110
    )


def check_titles():
    chat_shell.CONFIG = ChatApp(
        app_id="messenger", title="Messenger", url="https://www.messenger.com/",
        domains=("messenger.com",), notification_origins=(),
        debug_variable="MESSENGER_DEBUG",
    )
    # The fallback count, for a site that never calls the Badging API, and the
    # remainder the label is built from.
    counted = {
        "(3) Jessica Laureys": (3, "Jessica Laureys"),
        "Jessica Laureys": (0, "Jessica Laureys"),
        "Julie vous a envoyé un message": (0, "Julie vous a envoyé un message"),
        "": (0, ""),
    }
    for given, split in counted.items():
        assert parse_title(given) == split, given

    # window_title takes the title parse_title has already stripped.
    url = "https://www.messenger.com/e2ee/t/711?locale=fr_FR"
    labelled = {
        # What the site publishes, after the app's name and verbatim.
        ("Jessica Laureys", 0): "Messenger - Jessica Laureys",
        ("Julie vous a envoyé un message", 0):
            "Messenger - Julie vous a envoyé un message",
        # Already names the app, so it is left alone rather than doubled —
        # with the count still in front of it.
        ("Messenger", 0): "Messenger",
        ("Messenger", 2): "(2) Messenger",
        ("Julie Pauwels | Messenger", 3): "(3) Julie Pauwels | Messenger",
        ("Jessica Laureys", 3): "(3) Messenger - Jessica Laureys",
        # Qt's stand-in for a page with no title of its own, and the empty
        # title: the app's name rather than a URL in the label. This is
        # WhatsApp's permanent state, and the marker is all it ever gets.
        ("messenger.com/e2ee/t/711?locale=fr_FR", 5): "(5) Messenger",
        ("", 4): "(4) Messenger",
        ("", 0): "Messenger",
        # A substring of its own URL is still a conversation name, not the
        # stand-in: matching by containment would drop it from the label.
        ("711", 0): "Messenger - 711",
    }
    for (given, count), label in labelled.items():
        assert window_title(given, url, count) == label, (given, count)
    assert window_title(None, url, 0) == "Messenger"
    # The stand-in at a site's root — scheme, www and trailing slash all gone.
    # That is where WhatsApp permanently sits.
    assert window_title("messenger.com", "https://www.messenger.com/", 0) == "Messenger"


def check_reload_deferrals():
    """The two guards IdleReloader.tick has to get past to reload.

    They run once every twelve idle hours, so a misspelled Qt getter is an
    AttributeError nobody sees until then — and PyQt turns one raised in a slot
    into abort(), which is what killed both windows overnight.
    """
    for owner, method in ((QWebEngineView, "isActiveWindow"),
                          (QWebEnginePage, "recentlyAudible")):
        assert hasattr(owner, method), f"{owner.__name__}.{method}() is gone"


def main():
    check_titles()
    check_reload_deferrals()
    # Held: collecting it mid-test aborts Qt. Built after chat_shell is
    # imported, deliberately — QtWebEngine aborts if it arrives second.
    app = QApplication([])
    for dpr in (1.0, 2.0, 1.5):
        side = int(64 * dpr)
        pixmap = QPixmap(side, side)
        pixmap.setDevicePixelRatio(dpr)
        pixmap.fill(QColor("white"))
        paint_badge(pixmap, 3)
        found = red_pixels(pixmap.toImage())
        assert found > 100, f"dpr={dpr}: badge not visible ({found} red pixels)"
    print("ok", flush=True)
    del app


if __name__ == "__main__":
    main()
