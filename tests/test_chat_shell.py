#!/usr/bin/env python3
"""The two things the chat shell gets wrong silently.

The badge has to land inside the icon at any screen scale: sized off the
pixmap's physical width, it was drawn entirely outside the canvas on a scaled
screen — painted every time, visible never. And the fallback unread count is
the "(3)" a site prefixes its title with, which the label itself keeps verbatim.

Run: python3 tests/test_chat_shell.py
"""

import os
import sys
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent
                      / "home" / "dot_local" / "lib"))

import chat_shell
from chat_shell import ChatApp, paint_badge, unread_count, window_title
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
    counted = {
        "(3) Julie Pauwels | Messenger": 3,
        "Julie Pauwels | Messenger": 0,
        "Julie vous a envoyé un message": 0,  # the flash, alternated in and out
        "": 0,
    }
    for given, count in counted.items():
        assert unread_count(given) == count, given

    url = "https://www.messenger.com/e2ee/t/711?locale=fr_FR"
    labelled = {
        # What the site publishes, after the app's name and verbatim.
        "Jessica Laureys": "Messenger - Jessica Laureys",
        "(3) Jessica Laureys": "Messenger - (3) Jessica Laureys",
        "Julie vous a envoyé un message": "Messenger - Julie vous a envoyé un message",
        # Already names the app, so it is left alone rather than doubled.
        "Messenger": "Messenger",
        "Julie Pauwels | Messenger": "Julie Pauwels | Messenger",
        # Qt's stand-in for a page with no title of its own, and the empty
        # title: the app's name rather than a URL in the label.
        "messenger.com/e2ee/t/711?locale=fr_FR": "Messenger",
        "": "Messenger",
    }
    for given, label in labelled.items():
        assert window_title(given, url) == label, given
    assert window_title(None, url) == "Messenger"


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
