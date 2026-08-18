"""Application-agnostic chat shell built on Qt WebEngine.

Why this exists rather than a browser PWA: a Chromium or Firefox app window
never calls xdg-open, so a clicked link opens in whichever browser hosts the
app instead of the system default. It also inherits that browser's branding in
the window title, which no setting removes. Owning the window means owning the
title and the Wayland app_id, and routing links through xdg-open on purpose.

The engine matters: Qt WebEngine *is* Chromium, which is what modern chat sites
expect. Tauri would give WebKitGTK on Linux, a different and weaker engine for
this job.

It has a tray icon for the unread count, and a clicked notification comes back to
the conversation it came from. Closing the window quits: on Hyprland nothing is
ever buried, so there is no minimising habit for a background process to serve.

Deliberately not implemented: anything that reads a chat site's DOM. Scraping is
what turns a wrapper into a maintenance treadmill and eventually abandonware —
the unread count is the one the site publishes through the Badging API, and a
notification click is handed straight back to the site's own service worker
rather than resolved to a URL here.

QtWebEngine leaves that API unimplemented, so the shell supplies it (BADGE_SHIM)
and falls back to the "(3)" prefix on document.title for a site that never calls
it. The prefix is the poorer signal by far: it means "arrived while you were
away", so it is dropped the moment the window takes focus even with the message
still unread, and it is flashed on and off while it lasts.

Set the launcher's debug environment variable to 1 for a running commentary
plus F9, which dumps whatever modal or overlay is currently covering the page.
"""

import os
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from PyQt6.QtCore import (
    QElapsedTimer,
    QMetaType,
    QObject,
    QProcess,
    QRectF,
    QStandardPaths,
    Qt,
    QTimer,
    QUrl,
    pyqtSignal,
    pyqtSlot,
)
from PyQt6.QtDBus import QDBusArgument, QDBusConnection, QDBusInterface
from PyQt6.QtGui import (
    QColor,
    QDesktopServices,
    QIcon,
    QKeySequence,
    QPainter,
    QShortcut,
)
from PyQt6.QtNetwork import QLocalServer, QLocalSocket
from PyQt6.QtWebEngineCore import (
    QWebEnginePage,
    QWebEnginePermission,
    QWebEngineProfile,
    QWebEngineScript,
)
from PyQt6.QtWebEngineWidgets import QWebEngineView
from PyQt6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

NavigationRewrite = Callable[[str, str], str | None]


@dataclass(frozen=True)
class ChatApp:
    app_id: str
    title: str
    url: str
    domains: tuple[str, ...]
    notification_origins: tuple[str, ...]
    debug_variable: str
    allow_media_capture: bool = False
    fixed_icon_size: int | None = None
    rewrite_navigation: NavigationRewrite | None = None
    locale: str = "fr_FR"


CONFIG: ChatApp
DEBUG: bool

# Breeze has no "internet-chat" — the obvious name for a chat app is simply
# absent from the theme, so asking for it yields a null icon and a blank
# launcher entry. This one is a speech bubble and actually exists, and it is only
# ever a placeholder: the page favicon takes over everywhere once it loads, which
# gives the app its own glyph without shipping a trademarked file in this repo.
FALLBACK_ICON = "dialog-messages"
ICON_SIZE = 64        # the tray pixmap, and what the badge is sized against
ICON_CACHE_SIZE = 128  # what IconCache writes, for launchers to scale down from

# How long a page may accumulate before an unattended reload reclaims it.
# Measured on a renderer left on web.whatsapp.com for 29 hours: 2.14 GB, of
# which 1.94 GB is anonymous — Blink's image cache and the V8 heap, neither of
# which a running page ever gives back. A reload is the only lever that returns
# it, and Chromium's own answer — freezing or discarding a background tab — is
# not available here: a frozen page runs no JavaScript, so it would cost the
# unread badge and every notification, which is the only reason this process
# stays resident at all.
IDLE_RELOAD_HOURS = 12
RELOAD_CHECK_MINUTES = 5

# Internal hosts come from the launcher and are matched on the registrable
# suffix so subdomains are covered. Anything else goes to the default browser:
# this window has no back button, so leaving the configured app is a dead end.
# Navigation the user asked for, as opposed to the redirects and form posts the
# auth flow is made of. Built once: the check runs on every navigation.
USER_NAV_TYPES = frozenset({
    QWebEnginePage.NavigationType.NavigationTypeLinkClicked,
    QWebEnginePage.NavigationType.NavigationTypeTyped,
})

# org.freedesktop.Notifications: the bus name, object path and interface name.
# The service and the interface are spelled the same, which is why one constant
# does for both.
NOTIFY_SVC = "org.freedesktop.Notifications"
NOTIFY_PATH = "/org/freedesktop/Notifications"
NOTIFY_TIMEOUT_MS = 8000        # how long the daemon shows a notification
NOTIFY_CALL_TIMEOUT_MS = 2000   # how long we wait on the daemon to answer

# Action pairs, key then label, flattened the way the D-Bus signature wants
# them. "default" is the click on the notification body, which swaync
# deliberately keeps out of its button row — verified: it indexes "open" as
# action 0. "open" is therefore the visible button, and the fallback for any
# daemon that ignores the default action. Both keys do the same thing.
NOTIFY_LABEL = "Ouvrir"
NOTIFY_ACTIONS = ["default", NOTIFY_LABEL, "open", NOTIFY_LABEL]

# PyQt maps a Python int to D-Bus "i" and a list of str to "av", but Notify's
# signature is (susssasa{sv}i) — an unsigned id and a real string array. The
# mismatched arguments have to be typed explicitly or the call is rejected.
DBUS_UINT = QMetaType.Type.UInt.value
DBUS_STRLIST = QMetaType.Type.QStringList.value


def log(tag, msg):
    if DEBUG:
        print(f"[{tag}] {msg}", flush=True)


def data_home():
    return Path(QStandardPaths.writableLocation(
        QStandardPaths.StandardLocation.GenericDataLocation
    ))


def state_dir():
    d = data_home() / CONFIG.app_id
    d.mkdir(parents=True, exist_ok=True)
    return d


def is_within(host, domains):
    """True when host is one of these registrable domains, or a subdomain."""
    host = host.lower()
    return any(host == d or host.endswith("." + d) for d in domains)


def is_internal(host):
    return is_within(host, CONFIG.domains)


def unread_count(page_title):
    """The "(3)" a chat site puts in front of document.title, or 0.

    The fallback unread signal, for a site that never calls the Badging API. It
    reads no DOM node, which is what keeps the app out of the scraping
    treadmill.
    """
    m = re.match(r"^\((\d+)\)", (page_title or "").strip())
    return int(m.group(1)) if m else 0


def paint_badge(pixmap, count):
    """Stamp the unread count into the bottom-right corner of an icon."""
    # Logical size, not pixmap.width(): the tray icon is requested at ICON_SIZE
    # but comes back at ICON_SIZE * devicePixelRatio physical pixels, while
    # QPainter still addresses it in logical coordinates. Sizing the badge off
    # the physical width put it entirely outside the canvas on a scaled screen —
    # painted, and invisible.
    d = pixmap.deviceIndependentSize().width()
    box = QRectF(d * 0.45, d * 0.45, d * 0.55, d * 0.55)
    p = QPainter(pixmap)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QColor(220, 50, 60))
    p.drawEllipse(box)
    font = p.font()
    font.setBold(True)
    font.setPixelSize(int(box.height() * 0.7))
    p.setFont(font)
    p.setPen(QColor("white"))
    p.drawText(box, Qt.AlignmentFlag.AlignCenter, "9+" if count > 9 else str(count))
    p.end()


class IconCache:
    """The page favicon, mirrored to a file, so every surface shows one icon.

    The tray can take a live QIcon; nothing else can. rofi resolves Icon= out of
    the desktop entry while building its list, and the notification daemon
    resolves app_icon per notification — neither has anywhere to wait for a page
    to load, so both need a path that already exists. This writes one, seeded
    from the theme on the very first run and overwritten by the favicon after
    that, which is why the desktop entry can point at it unconditionally.

    Under hicolor rather than beside the app's profile: that is the directory the
    icon-theme spec has launchers search, and it means the entry's Icon= keeps
    working if it is ever changed from this absolute path to a bare name.
    """

    def __init__(self):
        cache_size = CONFIG.fixed_icon_size or ICON_CACHE_SIZE
        self.path = (data_home() / "icons" / "hicolor"
                     / f"{cache_size}x{cache_size}" / "apps"
                     / f"{CONFIG.app_id}.png")
        self.written = None
        if not self.path.exists() and CONFIG.fixed_icon_size is None:
            self.store(QIcon.fromTheme(FALLBACK_ICON))

    def store(self, icon):
        if icon.isNull():
            return
        image = icon.pixmap(ICON_CACHE_SIZE, ICON_CACHE_SIZE).toImage()
        # iconChanged fires several times per page load, with favicons that are
        # byte-identical but never the same QIcon. Comparing the rendered image
        # is what keeps this to a single write.
        if image == self.written:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if image.save(str(self.path), "PNG"):
            self.written = image
            log("ICON", f"cached {ICON_CACHE_SIZE}px -> {self.path}")
        else:
            log("ICON", f"could not write {self.path}")


class Tray(QSystemTrayIcon):
    """Tray presence and the unread badge.

    The badge is painted rather than looked up: no icon theme ships every app
    with every possible unread count. It is repainted only when the count
    actually changes, since titleChanged fires on every conversation switch.
    """

    def __init__(self, view, app):
        super().__init__(app)
        self.view = view
        self.base = QIcon.fromTheme(FALLBACK_ICON).pixmap(ICON_SIZE, ICON_SIZE)
        self.unread = 0
        self.pushed = None
        # Parented to the view, which owns it: setContextMenu does not take
        # ownership, and an unparented menu would be collected out from under
        # the tray icon.
        menu = QMenu(view)
        menu.addAction("Ouvrir", view.reveal)
        menu.addSeparator()
        # Reaches the app when its window is on another workspace or monitor,
        # which is the only thing the tray offers that the window does not.
        menu.addAction("Quitter", app.quit)
        self.setContextMenu(menu)
        self.activated.connect(self.on_activated)
        self.refresh()

    def set_base_icon(self, icon):
        """Adopt the page favicon — the app's own glyph, fetched not shipped."""
        if not icon.isNull():
            self.base = icon.pixmap(ICON_SIZE, ICON_SIZE)
            self.refresh()

    def set_unread(self, count):
        if count != self.unread:
            self.unread = count
            self.refresh()

    def refresh(self):
        pixmap = self.base.copy()
        if self.unread:
            paint_badge(pixmap, self.unread)
        s = "s" if self.unread > 1 else ""
        tip = (
            f"{self.unread} message{s} non lu{s}"
            if self.unread else CONFIG.title
        )
        # setIcon and setToolTip each emit a StatusNotifierItem signal, and every
        # one of those costs each tray host a GetAll reply carrying the whole
        # pixmap. iconChanged fires several times per page load, with favicons
        # that are byte-identical but never the same QIcon, so comparing the
        # result is what keeps those redundant rounds off the session bus.
        image = pixmap.toImage()
        if image != self.pushed:
            self.pushed = image
            self.setIcon(QIcon(pixmap))
        if tip != self.toolTip():
            self.setToolTip(tip)

    def on_activated(self, reason):
        # Raise, never toggle: closing the window quits the app, so there is no
        # hidden state for a second click to restore, and hiding a window is not
        # something this desktop does.
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self.view.reveal()


class ShellView(QWebEngineView):
    """The window. Closing it quits the app, tray icon or not.

    No close-to-background: on Hyprland every window is on a workspace you can
    reach, so minimising is a habit this desktop does not have, and an invisible
    process holding half a gigabyte of Chromium is a worse deal than a cold
    start. The tray icon is there for the unread badge, not as a place to hide.
    """

    def reveal(self):
        """Raise and focus, from the tray, a notification, or a relaunch.

        Lives here rather than on Tray because raising a window is the window's
        own business: hanging it off the tray is what would force notifications
        and the single-instance doorbell to hold a tray they have no use for,
        and to go silent when there is none.
        """
        self.raise_()
        self.activateWindow()
        # showNormal() must not be used here: a compositor-fullscreen window is
        # already visible, and normalising it exposes the rest of its Hyprland
        # group. Qt's activation request can then focus that group without
        # selecting this tab, so ask Hyprland to focus the app explicitly.
        if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
            selector = f'class:^({CONFIG.app_id})$'
            dispatcher = f'hl.dsp.focus({{ window = "{selector}" }})'
            QProcess.startDetached("hyprctl", ["dispatch", dispatcher])


class Notifier(QObject):
    """Desktop notifications that can be clicked back into the conversation.

    notify-send cannot do this: it exits before the user clicks, so the click has
    nowhere to land. QSystemTrayIcon.showMessage() cannot either — Qt discards
    the daemon's notification id and emits a bare messageClicked(), leaving
    nothing to match a click against. Talking to org.freedesktop.Notifications
    directly keeps the id, which is what lets ActionInvoked be matched back to
    the QWebEngineNotification it came from — and calling click() on that hands
    the click to the site's own service worker, which opens the right thread. No
    DOM read, no URL to parse, nothing tied to a site's markup.
    """

    def __init__(self, view, icon, parent):
        super().__init__(parent)
        bus = QDBusConnection.sessionBus()
        self.view = view
        # The cached favicon's path, so a notification carries the same icon as
        # the tray and the launcher. A path rather than a theme name: it resolves
        # whatever icon theme the daemon happens to be configured with.
        self.icon = str(icon)
        self.iface = QDBusInterface(NOTIFY_SVC, NOTIFY_PATH, NOTIFY_SVC, bus, self)
        # present() below has to block for the id it needs, and the libdbus
        # default would make that 25 seconds of frozen window whenever the daemon
        # is wedged or the bus is still activating it.
        self.iface.setTimeout(NOTIFY_CALL_TIMEOUT_MS)
        # Notifications the daemon still knows about, by its id, so ActionInvoked
        # can be routed back to one. Expiry signals nothing — swaync parks an
        # expired popup in its control center — so an entry outlives the popup
        # and is dropped on NotificationClosed or on the click itself.
        self.live = {}
        bus.connect(NOTIFY_SVC, NOTIFY_PATH, NOTIFY_SVC, "ActionInvoked",
                    self.on_action)
        bus.connect(NOTIFY_SVC, NOTIFY_PATH, NOTIFY_SVC, "NotificationClosed",
                    self.on_closed)

    def present(self, notification):
        # Nothing to say, so nothing is shown. A site that believes it is an
        # installed app receives background pushes with no user-visible payload,
        # and the push contract still obliges its service worker to raise a
        # notification for each one — which arrives here with an empty title and
        # an empty body, and would be a popup carrying only our own "Ouvrir".
        # The page is still told it was displayed, which is what it waits on.
        if not notification.title() and not notification.message():
            log("NOTIFY", "empty payload -> dropped")
            notification.show()
            return

        reply = self.iface.call(
            "Notify", CONFIG.title, QDBusArgument(0, DBUS_UINT), self.icon,
            notification.title(), notification.message(),
            QDBusArgument(NOTIFY_ACTIONS, DBUS_STRLIST),
            # Lets the daemon tie the notification back to the desktop entry,
            # for its icon and its per-app rules.
            {"desktop-entry": CONFIG.app_id}, NOTIFY_TIMEOUT_MS,
        )
        args = reply.arguments()
        if args:
            self.live[args[0]] = notification
        # Tells the page the notification was displayed, whatever the daemon did.
        notification.show()
        log("NOTIFY", f"{args or reply.errorMessage()} {notification.title()} :: "
                      f"{notification.message()[:50]}")

    @pyqtSlot("uint", str)
    def on_action(self, nid, key):
        notification = self.live.pop(nid, None)
        log("NOTIFY", f"action {key!r} on {nid} -> "
                      f"{'click' if notification else 'stale, ignored'}")
        if notification is not None:
            notification.click()
            self.view.reveal()

    @pyqtSlot("uint", "uint")
    def on_closed(self, nid, _reason):
        notification = self.live.pop(nid, None)
        if notification is not None:
            # Fires the page's own Notification.onclose, so the site's idea of
            # what is on screen keeps up with what the daemon actually dismissed.
            notification.close()


def hand_to_browser(url):
    """Send a URL to the system default browser.

    QDesktopServices.openUrl() is the idiomatic call and does work here, but it
    goes through the XDG portal and reports failure by returning False rather
    than raising, so the result is checked and xdg-open spawned as a fallback.
    """
    ok = QDesktopServices.openUrl(url)
    log("HANDOFF", f"openUrl -> {ok} for {url.toString()[:70]}")
    if not ok:
        spawned = QProcess.startDetached("xdg-open", [url.toString()])
        log("HANDOFF", f"fallback xdg-open -> {spawned}")


# Reports whatever is covering the page: every dialog, whatever is really
# painted in the top-left corner, and any bare "Close" affordance.
PROBE_JS = r"""
(() => {
  const desc = el => {
    if (!el) return null;
    const cs = getComputedStyle(el), r = el.getBoundingClientRect();
    return {
      tag: el.tagName, role: el.getAttribute('role') || null,
      label: el.getAttribute('aria-label') || null,
      pos: cs.position, z: cs.zIndex, bg: cs.backgroundColor,
      box: [Math.round(r.width), Math.round(r.height)],
      at: [Math.round(r.x), Math.round(r.y)],
      text: (el.innerText || '').trim().slice(0, 70).replace(/[ \t\n]+/g, ' '),
    };
  };
  const corners = [[10, 10], [30, 30], [60, 60]].map(([x, y]) => {
    const el = document.elementFromPoint(x, y);
    const d = desc(el);
    if (d && el) {
      d.chain = [];
      let a = el.parentElement;
      for (let i = 0; a && i < 5; i++, a = a.parentElement) {
        const role = a.getAttribute('role');
        d.chain.push(a.tagName + (role ? '[' + role + ']' : ''));
      }
    }
    return { pt: [x, y], el: d };
  });
  return JSON.stringify({
    path: location.pathname, title: document.title,
    dialogs: [...document.querySelectorAll('[role="dialog"],[role="alertdialog"],dialog')]
      .slice(0, 4).map(desc),
    corners,
    closers: [...document.querySelectorAll('div,span,button,a')]
      .filter(el => ['Fermer', 'Close'].includes((el.textContent || '').trim())
                    && el.children.length === 0)
      .slice(0, 3).map(desc),
  });
})()
"""


# The Badging API, which QtWebEngine leaves unimplemented: a page that asks for
# it gets `undefined` and falls back to flashing its title. Providing it is not
# scraping — it is the site telling us its own unread count, through the standard
# call it already makes as a PWA. console.info is the transport because it needs
# no QWebChannel and no injected object the page could trip over.
BADGE_MARKER = "[chat-shell:badge]"
BADGE_SHIM = f"""
(() => {{
  // A site only reaches for the Badging API once it believes it is an
  // installed app, and this window is exactly that: its own process, its own
  // app_id, no browser chrome. Claiming standalone is a description, not a lie.
  // A plain stand-in, not a doctored MediaQueryList: its `matches` is a
  // read-only accessor, so assigning to it throws and takes the shim with it.
  const media = window.matchMedia.bind(window);
  const noop = () => {{}};
  window.matchMedia = q => /display-mode:\\s*standalone/.test(q)
    ? {{matches: true, media: q, onchange: null, addEventListener: noop,
       removeEventListener: noop, addListener: noop, removeListener: noop,
       dispatchEvent: () => false}}
    : media(q);

  const send = n => console.info("{BADGE_MARKER} " + Math.max(0, n | 0));
  navigator.setAppBadge = n => (send(n === undefined ? 1 : n), Promise.resolve());
  navigator.clearAppBadge = () => (send(0), Promise.resolve());
  console.info("{BADGE_MARKER} ready " + (window.matchMedia("(display-mode: standalone)").matches ? "standalone" : "browser"));
}})();
"""


class ShellPage(QWebEnginePage):
    # The unread count the page published through the shimmed Badging API.
    badgePublished = pyqtSignal(int)

    def javaScriptConsoleMessage(self, level, message, line, source):
        if message.startswith(BADGE_MARKER):
            payload = message[len(BADGE_MARKER):].strip()
            if payload.isdigit():
                log("BADGE", f"page published {payload}")
                self.badgePublished.emit(int(payload))
            else:
                # The shim's own liveness line, which also says whether the page
                # believes it is standalone — the condition for it to ask at all.
                log("BADGE", payload)
            return
        super().javaScriptConsoleMessage(level, message, line, source)

    def acceptNavigationRequest(self, url, nav_type, is_main_frame):
        scheme = url.scheme()

        # The app's own plumbing: media viewer, downloads, PDF preview.
        if scheme in {"blob", "about", "data"}:
            return True

        # A sub-frame is part of the page, never the user leaving the app.
        # Ejecting cross-domain login or captcha frames would strand
        # authentication in another browser with no way back.
        if not is_main_frame:
            log("FRAME", f"sub-frame {url.host()} -> in-app")
            return True

        if scheme in {"http", "https"}:
            host = url.host()
            path = url.path()

            target_url = (
                CONFIG.rewrite_navigation(host, path)
                if CONFIG.rewrite_navigation else None
            )
            if target_url:
                target = QUrl(target_url)
                log("SCOPE", f"{host}{path[:40]} -> {target.toString()}")
                # Deferred: navigating while this handler is still deciding on a
                # navigation invites re-entrancy.
                QTimer.singleShot(0, lambda t=target: self.setUrl(t))
                return False

            # Only deliberate navigation leaves. Redirects and form posts are
            # the auth machinery working; they stay, whatever host they land on.
            if nav_type in USER_NAV_TYPES and not is_internal(host):
                log("EXTERNAL", f"{host} -> handing off")
                hand_to_browser(url)
                return False
            log("NAV", f"[{nav_type.name}] {host}{path[:50]}")

        return super().acceptNavigationRequest(url, nav_type, is_main_frame)

    def createWindow(self, _type):
        # target=_blank / window.open. The URL is only known once the throwaway
        # page begins loading it, hence the urlChanged detour.
        holder = QWebEnginePage(self.profile(), self)

        def hand_off(url):
            if url.isValid() and not url.isEmpty():
                if is_internal(url.host()):
                    # Some sites run parts of the auth flow in popups; sending those
                    # to another browser breaks login exactly as ejecting the
                    # captcha iframe did. setUrl re-enters
                    # acceptNavigationRequest, so scoping still applies.
                    log("POPUP", f"internal {url.host()} -> main view")
                    self.setUrl(url)
                else:
                    log("EXTERNAL", f"popup {url.host()} -> handing off")
                    hand_to_browser(url)

        # Single-shot: a popup that redirects would otherwise hand off twice.
        # The timer is what actually frees the page — window.open() with no URL
        # never emits urlChanged, and an undeleted holder keeps a whole
        # Chromium-side page alive for as long as the app runs.
        holder.urlChanged.connect(hand_off, Qt.ConnectionType.SingleShotConnection)
        QTimer.singleShot(10_000, holder.deleteLater)
        return holder


def badge_shim():
    """The Badging API polyfill, in the page's own world at document creation.

    MainWorld and DocumentCreation both matter: an isolated world would leave
    the page's own `navigator` untouched, and a later injection point would
    arrive after the site has already decided the API is missing.
    """
    script = QWebEngineScript()
    script.setName("badge-shim")
    script.setSourceCode(BADGE_SHIM)
    script.setInjectionPoint(QWebEngineScript.InjectionPoint.DocumentCreation)
    script.setWorldId(QWebEngineScript.ScriptWorldId.MainWorld)
    script.setRunsOnSubFrames(False)
    return script


def build_profile(app):
    profile = QWebEngineProfile(CONFIG.app_id, app)
    profile.scripts().insert(badge_shim())
    state = state_dir()
    profile.setPersistentStoragePath(str(state / "profile"))
    profile.setCachePath(str(state / "cache"))
    # Also persists session cookies, so the login survives a restart.
    profile.setPersistentCookiesPolicy(
        QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies
    )
    locale = CONFIG.locale
    profile.setHttpAcceptLanguage(
        f"{locale.replace('_', '-')},{locale[:2]};q=0.9,en;q=0.8"
    )

    # QtWebEngine denies every permission nobody handles, so
    # Notification.permission otherwise reads "denied", and sites may respond
    # with a permanent browser-settings warning. Granting it up front avoids
    # that false warning.
    profile.setPersistentPermissionsPolicy(
        QWebEngineProfile.PersistentPermissionsPolicy.StoreOnDisk
    )
    for origin in CONFIG.notification_origins:
        perm = profile.queryPermission(
            QUrl(origin), QWebEnginePermission.PermissionType.Notifications
        )
        if perm.isValid():
            perm.grant()
        log("PERM", f"{origin} -> valid={perm.isValid()} state={perm.state().name}")

    # Only the permission is granted here; presenting a notification is the
    # caller's job (see Notifier), which needs the window a click comes back to.

    # Qt advertises "QtWebEngine/x.y.z Chrome/N". Some sites gate on the user
    # agent, so the Qt token is dropped to present as plain Chrome — derived
    # from the bundled Chromium rather than hardcoded, so it cannot go stale.
    ua = re.sub(r"QtWebEngine/\S+\s*", "", profile.httpUserAgent()).strip()
    profile.setHttpUserAgent(ua)
    log("UA", ua)
    return profile


class ColorSchemeFollower(QObject):
    """Carries the desktop's light/dark mode into the page, and keeps it there.

    Two effects, one flip: the colour painted under the page, and a reload so
    the page re-samples prefers-color-scheme.

    The window is nothing but the page, so the desktop appearance reaches it
    only as prefers-color-scheme — and QtWebEngine samples that once, when a
    page loads. Qt itself keeps up: the KDE platform theme (QT_QPA_PLATFORMTHEME
    =kde, which is what makes KDE the canonical source of the mode here)
    repaints the palette and emits colorSchemeChanged as soon as
    plasma-apply-colorscheme runs. The page that is already loaded is simply
    never told. Measured: styleHints().colorScheme() flips to Dark while the
    page goes on matching (prefers-color-scheme: light) indefinitely, and a
    reload is what re-samples it. Qt 6.11 offers no runtime setter — only the
    ForceDarkMode attribute, which is Chromium inverting the page itself, and
    worth nothing to a site that ships a real dark theme of its own.

    A reload is also all this can do. Whether the site then follows is the
    site's own business: both Messenger and WhatsApp Web keep a per-account
    appearance setting that has to be on its "system"/"automatic" option for
    prefers-color-scheme to mean anything.
    """

    def __init__(self, app, page):
        super().__init__(app)
        self.page = page
        # Held rather than fetched per use: PyQt parks the proxy for a connected
        # Python callable on the *sender's* wrapper, and the wrapper for an
        # app-owned QStyleHints reached through a local is collected soon after.
        # Measured: the connection went with it and the reload silently stopped
        # happening, while a reference held elsewhere kept firing.
        self.hints = app.styleHints()
        self.loaded_with = self.hints.colorScheme()
        self.hints.colorSchemeChanged.connect(self.on_scheme_changed)
        self.apply_background()

    def apply_background(self):
        """Paint under the page in the palette's colour, not Qt's flat white.

        White is what Qt paints whatever the theme, which is a full-window flash
        on every load and reload while the desktop is dark. Base rather than
        Window: this sits under a document, not behind widget chrome.
        """
        self.page.setBackgroundColor(QApplication.palette().base().color())

    def on_scheme_changed(self, scheme):
        # Guarded on the scheme the page actually loaded with, and hung off
        # colorSchemeChanged rather than paletteChanged: that one fires twice per
        # flip and for changes that are not the scheme at all, and a reload costs
        # a resync plus any half-typed message.
        if scheme == self.loaded_with:
            log("SCHEME", f"{scheme.name} unchanged -> no reload")
            return
        self.loaded_with = scheme
        self.apply_background()
        log("SCHEME", f"{scheme.name} -> reloading to re-sample")
        # Deferred, and not for tidiness: Qt hands the new scheme to the render
        # process from its own queued settings batch, so a reload started inside
        # this handler is still sampled against the old one. Measured — it came
        # back one flip behind, dark desktop and a light page, and one turn of
        # the event loop is the whole difference.
        QTimer.singleShot(
            0, lambda: self.page.triggerAction(QWebEnginePage.WebAction.Reload)
        )


class IdleReloader(QObject):
    """Reload the page once it has been left alone long enough.

    The clock is the time since the last finished load, not since the last
    reload this class started, so a manual F5 or a colour-scheme flip counts as
    the same reclaim and the timer never fires on top of one.

    Elapsed rather than wall-clock time on purpose: a laptop that suspends for
    the night would otherwise come back to a page "idle" for nine hours and
    reload it under the user's hands at the first keystroke.
    """

    def __init__(self, view, page):
        super().__init__(view)
        self.view = view
        self.page = page
        self.since_load = QElapsedTimer()
        self.since_load.start()
        page.loadFinished.connect(lambda ok: self.since_load.start())
        timer = QTimer(self)
        timer.timeout.connect(self.tick)
        timer.start(RELOAD_CHECK_MINUTES * 60_000)

    def tick(self):
        if self.since_load.elapsed() < IDLE_RELOAD_HOURS * 3_600_000:
            return
        # Never under the user's hands: a reload costs the scroll position and
        # anything half-typed, so a focused window is off limits and the check
        # simply comes back in five minutes. The page keeps growing until then,
        # which is nothing next to a message lost mid-sentence.
        if self.view.isActiveWindow():
            log("RELOAD", "window focused -> deferred")
            return
        # Audible means a call or a voice note is playing, and a reload would
        # cut it. Same deferral, same reasoning.
        if self.page.recentlyAudible():
            log("RELOAD", "page audible -> deferred")
            return
        log("RELOAD", f"idle {IDLE_RELOAD_HOURS}h -> reclaiming")
        self.page.triggerAction(QWebEnginePage.WebAction.Reload)


def bind_shortcuts(view, page):
    """Wire the browser keys by hand.

    A bare QWebEngineView binds none of these: QtWebEngine handles text-editing
    keys internally and nothing else, so every affordance a browser gives for
    free has to be written out here.
    """
    def zoom(step):
        view.setZoomFactor(max(0.5, min(view.zoomFactor() + step, 3.0)))

    act = QWebEnginePage.WebAction
    bindings = [
        ("F5", lambda: page.triggerAction(act.Reload)),
        ("Ctrl+R", lambda: page.triggerAction(act.Reload)),
        ("Ctrl+Shift+R", lambda: page.triggerAction(act.ReloadAndBypassCache)),
        ("Ctrl+0", lambda: view.setZoomFactor(1.0)),
        ("Ctrl++", lambda: zoom(0.1)),
        ("Ctrl+-", lambda: zoom(-0.1)),
    ]
    if DEBUG:
        bindings.append(
            ("F9", lambda: page.runJavaScript(
                PROBE_JS, lambda r: log("PROBE", r)))
        )

    # Each shortcut is parented to the view, which owns it for the app's
    # lifetime — nothing here needs holding onto.
    for seq, fn in bindings:
        QShortcut(QKeySequence(seq), view).activated.connect(fn)


def socket_path():
    """Where the single-instance socket lives.

    Under XDG_RUNTIME_DIR, which is per-user and 0700, like the lock file this
    replaced. A bare name — QLocalServer's own default — would put it in the
    world-writable /tmp, where any local user can pre-create it and either wedge
    every launch or answer the doorbell themselves, and where systemd-tmpfiles
    can unlink it from under a running app.
    """
    runtime = QStandardPaths.writableLocation(
        QStandardPaths.StandardLocation.RuntimeLocation
    ) or str(state_dir())
    return str(Path(runtime) / f"{CONFIG.app_id}.sock")


def doorbell_answered(path):
    """True when an instance was already listening, and has been told to show.

    One Chromium stack is enough — a second instance costs a few hundred
    megabytes for a duplicate window. A pid lock could only *refuse*, and a
    refusal reads as a broken launcher: the window is open on some other
    workspace or monitor, and clicking the icon prints to a stderr nobody sees.
    A socket both excludes and delivers, so the second launch raises the window
    where it actually is. Connecting is the whole message; there is nothing to
    write.
    """
    probe = QLocalSocket()
    probe.connectToServer(path)
    return probe.waitForConnected(200)


def listen_for_doorbell(app, path):
    """Answer later launches for the rest of this process's life."""
    # Nothing answered the probe, so a socket file still sitting here is the
    # debris of an instance that was killed rather than closed — and listen()
    # would fail on it.
    QLocalServer.removeServer(path)
    server = QLocalServer(app)
    if not server.listen(path):
        # Not fatal: this instance runs, later launches just cannot reach it.
        log("INSTANCE", f"listen {path} failed: {server.errorString()}")
    return server


def run(config: ChatApp) -> int:
    global CONFIG, DEBUG

    CONFIG = config
    DEBUG = os.environ.get(config.debug_variable) == "1"
    allowed_permission_types = {
        QWebEnginePermission.PermissionType.Notifications,
    }
    if config.allow_media_capture:
        allowed_permission_types.update({
            QWebEnginePermission.PermissionType.MediaAudioCapture,
            QWebEnginePermission.PermissionType.MediaVideoCapture,
            QWebEnginePermission.PermissionType.MediaAudioVideoCapture,
        })

    # Before QApplication, deliberately: every launcher click made while the app
    # is already running ends here, and it has no use for the platform, portal
    # and theme initialisation that costs.
    sock = socket_path()
    if doorbell_answered(sock):
        log("INSTANCE", "already running -> asked it to show itself")
        return 0

    app = QApplication(sys.argv)
    app.setApplicationName(config.title)
    app.setDesktopFileName(config.app_id)  # drives the Wayland app_id

    server = listen_for_doorbell(app, sock)
    profile = build_profile(app)
    icons = IconCache()
    cached_icon = QIcon(str(icons.path))
    initial_icon = (cached_icon if not cached_icon.isNull()
                    else QIcon.fromTheme(FALLBACK_ICON))
    app.setWindowIcon(initial_icon)

    view = ShellView()
    page = ShellPage(profile, view)
    view.setPage(page)

    # Unheld, and parented to the app which owns it: nothing else here needs to
    # reach it, but a follower left to a local would take its signal connection
    # with it when collected. Here rather than lower down because it paints the
    # background as it is built, and that has to land before the first load or
    # a dark desktop gets a white flash.
    ColorSchemeFollower(app, page)

    # The tray icon carries the unread badge, and nothing depends on it: with no
    # StatusNotifier host (waybar's tray module, here) the app is simply a window.
    tray = None
    if QSystemTrayIcon.isSystemTrayAvailable():
        tray = Tray(view, app)
        tray.set_base_icon(initial_icon)
        if config.fixed_icon_size is None:
            view.iconChanged.connect(tray.set_base_icon)
        tray.show()
    else:
        log("TRAY", "no system tray available -> window-only mode")

    # quitOnLastWindowClosed is true, and it is not enough: a visible
    # QSystemTrayIcon makes Qt keep the process running when the last window
    # closes, which is exactly how a close-to-tray app is built. Measured — the
    # window closed, no visible top-level widget was left, lastWindowClosed did
    # fire, and the process stayed up until this connect was added. Suppressed is
    # only Qt's own response to the signal, not the signal, so asking for the
    # quit here is all it takes.
    app.lastWindowClosed.connect(app.quit)

    # The favicon reaches the launcher and the notification daemon through the
    # cache file, and the window and tray directly. One icon, four surfaces.
    view.setWindowIcon(initial_icon)
    if config.fixed_icon_size is None:
        view.iconChanged.connect(icons.store)
        view.iconChanged.connect(view.setWindowIcon)

    # Both of these only need the window, so both work without a tray.
    profile.setNotificationPresenter(Notifier(view, icons.path, app).present)

    def on_doorbell():
        server.nextPendingConnection().deleteLater()
        log("INSTANCE", "second launch -> revealing")
        view.reveal()

    server.newConnection.connect(on_doorbell)

    def on_permission(permission):
        kind = permission.permissionType()
        allow = kind in allowed_permission_types and is_internal(
            permission.origin().host()
        )
        permission.grant() if allow else permission.deny()
        log("PERM", f"request {kind.name} from {permission.origin().host()}"
                    f" -> {'grant' if allow else 'deny'}")

    # Set once the page publishes its own count, after which the title is no
    # longer read: a site that calls setAppBadge knows what is unread, while its
    # title only ever meant "arrived while you were away" — dropped the moment
    # the window takes focus, and flashed on and off in the meantime.
    published = False

    def show_unread(count):
        if tray is not None:
            tray.set_unread(count)

    def on_title(page_title):
        # Verbatim, "(3)" prefix and the line a site flashes while a message
        # waits ("Julie vous a envoyé un message") included: a Waybar label
        # reading "Messenger" forever is the one thing it never needed to be
        # told. The cost is a label that flashes with the site, and that shows
        # the bare URL Qt reports for the second a page spends loading.
        title = (page_title or "").strip()
        count = unread_count(title)
        log("TITLE", f"{title!r} / {count} unread")
        if title:
            view.setWindowTitle(title)
        if not published:
            show_unread(count)

    def on_badge(count):
        nonlocal published
        published = True
        show_unread(count)

    page.badgePublished.connect(on_badge)
    page.permissionRequested.connect(on_permission)
    profile.downloadRequested.connect(lambda download: download.accept())
    view.titleChanged.connect(on_title)
    if DEBUG:
        view.loadFinished.connect(
            lambda ok: log("LOAD", "ok" if ok else "FAILED"))

    bind_shortcuts(view, page)

    # Unheld and parented to the view, like ColorSchemeFollower above: the view
    # outlives every reload this starts, and a local would take the timer's
    # connection with it when collected.
    IdleReloader(view, page)

    view.setWindowTitle(config.title)
    view.resize(1280, 900)
    view.load(QUrl(config.url))
    view.show()

    return app.exec()
