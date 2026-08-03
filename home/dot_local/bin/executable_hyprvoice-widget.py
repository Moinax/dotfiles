#!/usr/bin/env python3

# Hyprvoice dictation overlay — a layer-shell pill showing the live microphone
# level while hyprvoice records, plus pointer controls (validate / cancel) so a
# dictation can be driven without reaching for Mod+D.
#
# toggle-dictation.sh launches it on the keypress that *starts* a dictation; it
# exits on its own once hyprvoice reports idle. A second launch is a no-op
# (GtkApplication single-instance), so a double Mod+D cannot stack two overlays.
#
# Three hyprvoice behaviours shape this, all established by probing the daemon:
#
#   * `status` reports "transcribing" from a few ms after capture begins — the
#     transcriber collects audio concurrently with the recorder — so it cannot
#     tell capture apart from the API call. The phase signal used instead is
#     the daemon's own `pw-record` child: alive while capturing, gone after.
#   * the daemon never reaps that child, so a bare "does the pid exist" check
#     reads as "still capturing" forever. Zombies must be filtered by state.
#   * the control socket dispatches on a command's *first byte* only, and only
#     lowercase ("subscribe" is answered as "status", "STATUS" is an error).
#     There is no event stream, hence the poll.
#
# The level meter is deliberately a second, independent capture stream rather
# than anything hyprvoice reports: PipeWire fans one source out to every
# client, so this observes exactly what the daemon is recording. That makes a
# dead microphone visible *while speaking* instead of surfacing as a bogus
# transcription afterwards (silence makes Whisper emit a stray " you").
#
# The exec bit comes from chezmoi's executable_ prefix at apply time, so the
# source file here is (and stays) mode 644 like every other script in this dir.
# ruff: noqa: EXE001

import json
import math
import os
import socket
import struct
import subprocess
import sys
from collections import deque
from pathlib import Path

import tomllib

PRELOAD = "/usr/lib/libgtk4-layer-shell.so"


def reexec_with_preload() -> None:
    """Re-exec with gtk4-layer-shell preloaded, once.

    The library has to precede libwayland-client in the link order; loaded
    through PyGObject it never does, and the surface then silently degrades to
    an ordinary toplevel. That is not a cosmetic failure: a toplevel takes
    keyboard focus, so hyprvoice would inject the transcription into *this*
    overlay instead of the window the user was typing in. LD_PRELOAD is
    upstream's documented fix (see gtk4-layer-shell/linking.md).
    """
    if os.environ.get("HYPRVOICE_WIDGET_PRELOADED"):
        return
    env = dict(os.environ)
    env["HYPRVOICE_WIDGET_PRELOADED"] = "1"
    if Path(PRELOAD).exists():
        env["LD_PRELOAD"] = ":".join(filter(None, (PRELOAD, env.get("LD_PRELOAD"))))
    # GTK4 otherwise picks this machine's outputless Intel iGPU for layer
    # surfaces and paints them solid black; the Cairo renderer sidesteps the
    # GPU pick entirely and is ample for a pill this size.
    env.setdefault("GSK_RENDERER", "cairo")
    os.execve(sys.executable, [sys.executable, os.path.abspath(__file__), *sys.argv[1:]], env)


reexec_with_preload()

# Imports below the re-exec on purpose: gi has to follow the LD_PRELOAD swap,
# and require_version has to precede the gi.repository imports.
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")

from gi.repository import Gio, GLib, Gtk
from gi.repository import Gtk4LayerShell as LayerShell

CACHE = Path.home() / ".cache" / "hyprvoice"
SOCKET_PATH = CACHE / "control.sock"
PID_PATH = CACHE / "hyprvoice.pid"
CONFIG_PATH = Path.home() / ".config" / "hyprvoice" / "config.toml"

BARS = 44  # waveform columns, newest on the right
BAR_MS = 45  # audio per column
POLL_MS = 120  # hyprvoice status / phase poll
FRAME_MS = 33  # ~30 fps; the ripple reads smooth and the pill is tiny
SILENT_AFTER_S = 2.0  # flag a digitally-silent source after this long
FLOOR_DB = -55.0  # quietest level the meter still shows movement for
ROW_GAP = 8  # one gap value for every element in the control row
PILL_WIDTH = 470  # fixed, so the waveform can absorb every width change
WAVE_MIN = 140  # floor for the waveform; hexpand gives it whatever is left

# hyprvoice's own capture format (`pw-record --format s16 --rate 16000
# --channels 1`), mirrored so the meter and the daemon hear the same thing.
RATE = 16000
BAR_BYTES = RATE * BAR_MS // 1000 * 2


# Both palettes live here rather than in style-{dark,light}.css: the waveform is
# Cairo-drawn, so its colours must be Python either way, and splitting one
# palette across two files is how a widget quietly stops matching itself. The
# overlay is short-lived and reads the scheme once at startup, so it has no need
# for swayosd's live-switching setup.
#
# Written as hex and converted here, not as float triples: #1e1e2e appears in
# eleven other files (waybar, swaync, swayosd, wlogout, rofi, yazi, theme.lua),
# and a flavour tweak has to be able to find this one by grepping for the same
# string as the rest. Cairo wants 0..1 floats, so the conversion happens once at
# import rather than being baked into the source.
def rgba(colour: str, alpha: float = 1.0) -> tuple[float, float, float, float]:
    r, g, b = (int(colour[i : i + 2], 16) / 255.0 for i in (1, 3, 5))
    return r, g, b, alpha


DARK = {  # Catppuccin Mocha
    "bg": rgba("#1e1e2e", 0.94),  # base
    "rim": rgba("#cdd6f4", 0.10),
    "ink": rgba("#cdd6f4"),  # text
    "dim": rgba("#a6adc8"),  # timer
    "accent": rgba("#cba6f7"),  # mauve
    "alert": rgba("#f38ba8"),  # red
    "ok": rgba("#a6e3a1"),  # green
}
LIGHT = {  # Catppuccin Latte
    "bg": rgba("#eff1f5", 0.96),  # base
    "rim": rgba("#4c4f69", 0.12),
    "ink": rgba("#4c4f69"),
    "dim": rgba("#6c6f85"),
    "accent": rgba("#8839ef"),
    "alert": rgba("#d20f39"),
    "ok": rgba("#40a02b"),
}

CSS = """
window.hv {{ background: transparent; }}
box.pill {{
  background: rgba({bg_r}, {bg_g}, {bg_b}, {bg_a});
  border: 1px solid rgba({rim_r}, {rim_g}, {rim_b}, {rim_a});
  border-radius: 999px;
  padding: 4px 14px 4px 10px;
}}
label.state {{
  color: rgb({dim_r}, {dim_g}, {dim_b});
  font-family: "JetBrainsMono Nerd Font", "FiraCode Nerd Font", monospace;
  font-size: 13px;
}}
label.state.alert {{ color: rgb({alert_r}, {alert_g}, {alert_b}); }}
button.act {{
  min-width: 22px;
  min-height: 22px;
  padding: 0;
  border: none;
  border-radius: 999px;
  background: rgba({rim_r}, {rim_g}, {rim_b}, 0.55);
  color: rgb({ink_r}, {ink_g}, {ink_b});
  font-size: 11px;
  transition: background 120ms ease, color 120ms ease;
}}
button.act:hover {{ background: rgba({ink_r}, {ink_g}, {ink_b}, 0.20); }}
button.act.ok:hover {{ color: rgb({ok_r}, {ok_g}, {ok_b}); }}
button.act.no:hover {{ color: rgb({alert_r}, {alert_g}, {alert_b}); }}
button.act:disabled {{ opacity: 0.35; background: rgba({rim_r}, {rim_g}, {rim_b}, 0.30); }}
label.source {{
  color: rgb({dim_r}, {dim_g}, {dim_b});
  font-size: 10.5px;
  /* Negative vertical margins let the name overhang its own line, so it costs
   * ~6px of height rather than a full text line. Without this the control row
   * is pushed a full line below the pill's centre and reads bottom-heavy. */
  margin: -4px 6px -5px 0;
}}
/* GtkMenuButton's CSS node is `menubutton`, wrapping a `button` child — a
 * `button.micbtn` selector matches neither, so the platform theme's raised
 * button showed through as a dark slab around the mic. Both nodes have to be
 * flattened, background-image included (the theme paints its gradient there). */
menubutton.micbtn,
menubutton.micbtn > button {{
  min-width: 30px;
  min-height: 30px;
  padding: 0;
  margin: 0;
  border: none;
  outline: none;
  box-shadow: none;
  background: none;
  background-image: none;
  border-radius: 999px;
}}
menubutton.micbtn > button:hover {{ background: rgba({ink_r}, {ink_g}, {ink_b}, 0.10); }}
menubutton.micbtn > button:checked {{ background: rgba({ink_r}, {ink_g}, {ink_b}, 0.14); }}
popover > contents {{
  background: rgba({bg_r}, {bg_g}, {bg_b}, {bg_a});
  border: 1px solid rgba({rim_r}, {rim_g}, {rim_b}, {rim_a});
  border-radius: 14px;
  padding: 6px;
}}
popover > arrow {{
  background: rgba({bg_r}, {bg_g}, {bg_b}, {bg_a});
  border: 1px solid rgba({rim_r}, {rim_g}, {rim_b}, {rim_a});
}}
button.srcrow {{
  border: none;
  background: transparent;
  border-radius: 9px;
  padding: 5px 9px;
  color: rgb({dim_r}, {dim_g}, {dim_b});
  font-size: 12.5px;
}}
button.srcrow:hover {{ background: rgba({ink_r}, {ink_g}, {ink_b}, 0.14); }}
button.srcrow.on {{ color: rgb({accent_r}, {accent_g}, {accent_b}); }}
label.srcnone {{
  color: rgb({dim_r}, {dim_g}, {dim_b});
  font-size: 12.5px;
  padding: 5px 9px;
}}
"""


def css_for(palette: dict) -> bytes:
    fields = {}
    for name, (r, g, b, a) in palette.items():
        fields[f"{name}_r"] = round(r * 255)
        fields[f"{name}_g"] = round(g * 255)
        fields[f"{name}_b"] = round(b * 255)
        fields[f"{name}_a"] = a
    return CSS.format(**fields).encode()


def prefers_dark() -> bool:
    """Follow the desktop colour scheme, the same signal apply-dark-mode.sh sets."""
    try:
        source = Gio.SettingsSchemaSource.get_default()
        if source and source.lookup("org.gnome.desktop.interface", True):
            scheme = Gio.Settings.new("org.gnome.desktop.interface").get_string("color-scheme")
            return scheme != "prefer-light"
    except (GLib.Error, TypeError):
        pass
    return True


def send_command(command: str) -> str | None:
    """One request/response round-trip on the hyprvoice control socket."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.5)
            sock.connect(str(SOCKET_PATH))
            sock.sendall(command.encode() + b"\n")
            return sock.recv(512).decode(errors="replace").strip()
    except OSError:
        return None


def daemon_status() -> str | None:
    """"idle" / "recording" / "transcribing", or None if the daemon is gone."""
    reply = send_command("status")
    if not reply:
        return None
    for field in reply.split():
        if field.startswith("status="):
            return field.partition("=")[2]
    return None


def capture_active() -> bool:
    """True while the daemon's pw-record child is still capturing.

    Two traps here, both verified against the running daemon:

    * every thread has its own children list, and hyprvoice being Go, the
      recorder is parented to whichever of its ~18 threads happened to fork it
      — never reliably the main one. Reading task/<pid>/children alone finds
      nothing, which reads as "capture already finished" the whole time.
    * the daemon never reaps a finished recorder, so the zombies pile up (four
      of them within one session). Existence proves nothing; state does.
    """
    try:
        pid = PID_PATH.read_text().strip()
        children = []
        for task in Path(f"/proc/{pid}/task").iterdir():
            try:
                children += (task / "children").read_text().split()
            except OSError:
                continue
    except OSError:
        return False
    for child in children:
        try:
            stat = Path(f"/proc/{child}/stat").read_text()
        except OSError:
            continue
        # comm is parenthesised and may itself contain spaces or parens, so
        # split on the *last* ')': what follows is the single-letter state.
        name = stat[stat.find("(") + 1 : stat.rfind(")")]
        tail = stat[stat.rfind(")") + 1 :].split()
        if name == "pw-record" and tail and tail[0] != "Z":
            return True
    return False


def run_pactl(args: list[str]) -> str | None:
    try:
        done = subprocess.run(
            ["pactl", *args], capture_output=True, text=True, timeout=2.0, check=True
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout


def pactl_json(args: list[str]) -> list:
    """`pactl -f json …`, or an empty list on any failure.

    One place answers "did pactl run, and was the output parseable" — the three
    callers below would otherwise each carry the same pair of early returns.
    """
    raw = run_pactl(["-f", "json", *args])
    try:
        return json.loads(raw) if raw else []
    except ValueError:
        return []


def pinned_device() -> str | None:
    """hyprvoice's `[recording] device`, when it names one.

    Empty (the shipped default) means "follow the PipeWire default source",
    which is what makes the picker below effective. A pinned device overrides
    it, so the picker says so instead of quietly doing nothing.
    """
    try:
        with CONFIG_PATH.open("rb") as handle:
            device = tomllib.load(handle).get("recording", {}).get("device", "")
    except (OSError, tomllib.TOMLDecodeError):
        return None
    return device or None


def default_source() -> str:
    """The name PipeWire hands to a client that asks for no device in particular."""
    return (run_pactl(["get-default-source"]) or "").strip()


def capture_inputs(sources: list) -> list[tuple[str, str]]:
    """(name, description) of every capture device in a dump, monitors excluded.

    Takes the parsed dump rather than fetching it, like find_source below: the
    caller needs that same `list sources` output for the tick column anyway, and
    re-fetching it per question is how raising one pill cost four pactl execs.
    """
    inputs = []
    for source in sources:
        name = source.get("name") or ""
        if name and not name.endswith(".monitor"):
            inputs.append((name, source.get("description") or name))
    return inputs


def find_source(sources: list, name: str) -> dict | None:
    for source in sources:
        if source.get("name") == name:
            return source
    return None


def ensure_audible(source: dict) -> None:
    """Unmute `source` and lift a zeroed level, so it can actually be heard.

    A source muted in the mixer records perfect silence while every status the
    OS reports still looks healthy — the same dead end as a hardware-muted
    headset, but this one is ours to fix. Done whenever dictation is pointed at
    a device (including at startup): reaching for Mod+D is an unambiguous
    request for the microphone to work, and the alternative is a recording that
    silently transcribes to nothing.

    Both fixes are conditional on what the dump already says, so the common case
    — a healthy microphone — spends no pactl exec at all.
    """
    name = source.get("name")
    if not name:
        return
    if source.get("mute"):
        run_pactl(["set-source-mute", name, "0"])
    levels = (source.get("volume") or {}).values()
    # Only rescue a fully closed channel; any audible level is the user's.
    if levels and all(c.get("value_percent") == "0%" for c in levels):
        run_pactl(["set-source-volume", name, "100%"])


def short_name(description: str) -> str:
    """Device description trimmed of the channel-layout tail PipeWire appends."""
    for suffix in (" Analog Stereo", " Digital Stereo", " Mono", " Stereo"):
        if description.endswith(suffix):
            return description[: -len(suffix)]
    return description


def select_input(name: str) -> None:
    """Point dictation at `name`, both now and for the next recording.

    set-default-source covers streams yet to start; the move covers the two
    already running — hyprvoice's recorder and this overlay's meter — so the
    swap lands mid-sentence instead of at the next Mod+D. Only pw-record
    streams are moved: sweeping every capture stream would also drag whatever
    else holds the microphone, a browser call included.
    """
    run_pactl(["set-default-source", name])
    for stream in pactl_json(["list", "source-outputs"]):
        # pw-record sets no application.process.id, so the stream is claimed by
        # application.name — the only field that identifies it here.
        if stream.get("properties", {}).get("application.name") == "pw-record":
            run_pactl(["move-source-output", str(stream["index"]), name])


class LevelMeter:
    """Rolling RMS of the default PipeWire source, as waveform columns.

    Runs its own `pw-record` on the same node the daemon reads; PipeWire fans a
    source out to every client, so this costs nothing but sees the same audio.
    """

    def __init__(self, on_column):
        self.on_column = on_column
        self.proc: subprocess.Popen | None = None
        self.buffer = bytearray()
        self.watch: int | None = None
        self.heard_signal = False  # any non-zero sample at all

    def start(self) -> None:
        try:
            self.proc = subprocess.Popen(
                [
                    "pw-record",
                    "--raw",
                    "--format", "s16",
                    "--rate", str(RATE),
                    "--channels", "1",
                    "--latency", "20ms",
                    "-",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            return
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.watch = GLib.io_add_watch(
            GLib.IOChannel.unix_new(self.proc.stdout.fileno()),
            GLib.PRIORITY_DEFAULT,
            GLib.IOCondition.IN | GLib.IOCondition.HUP,
            self._on_readable,
        )

    def _on_readable(self, _channel, condition) -> bool:
        if condition & GLib.IOCondition.HUP:
            return False
        try:
            chunk = self.proc.stdout.read(BAR_BYTES * 4)
        except (OSError, ValueError):
            return False
        if chunk:
            self.buffer.extend(chunk)
            while len(self.buffer) >= BAR_BYTES:
                window = bytes(self.buffer[:BAR_BYTES])
                del self.buffer[:BAR_BYTES]
                self.on_column(self._level(window))
        return True

    def _level(self, window: bytes) -> float:
        samples = struct.unpack(f"<{len(window) // 2}h", window)
        total = sum(float(s) * s for s in samples)
        rms = math.sqrt(total / len(samples)) if samples else 0.0
        if rms <= 0:
            return 0.0
        # rms > 0 is exactly "some sample was non-zero", so the guard above
        # doubles as the aliveness test — no separate peak/trough pass needed.
        self.heard_signal = True
        # Speech spans a wide amplitude range, so map dB rather than raw
        # amplitude — otherwise normal talking barely lifts the bars.
        db = 20.0 * math.log10(rms / 32768.0)
        return min(1.0, max(0.0, (db - FLOOR_DB) / -FLOOR_DB))

    def stop(self) -> None:
        if self.watch is not None:
            GLib.source_remove(self.watch)
            self.watch = None
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
        self.proc = None


class Overlay:
    def __init__(self, app):
        self.palette = DARK if prefers_dark() else LIGHT
        self.levels = deque([0.0] * BARS, maxlen=BARS)
        self.phase = "listening"  # listening | transcribing
        self.started_us = GLib.get_monotonic_time()
        # When this *device* started being listened to, which the picker resets
        # and the dictation timer does not — the two questions came apart the
        # moment a mic could be swapped mid-sentence.
        self.device_since = self.started_us

        self.window = Gtk.ApplicationWindow(application=app)
        self.window.add_css_class("hv")
        LayerShell.init_for_window(self.window)
        LayerShell.set_layer(self.window, LayerShell.Layer.OVERLAY)
        LayerShell.set_anchor(self.window, LayerShell.Edge.BOTTOM, True)
        LayerShell.set_margin(self.window, LayerShell.Edge.BOTTOM, 90)
        # NONE, emphatically: an overlay that takes keyboard focus would become
        # the injection target and swallow the dictation it is reporting on.
        LayerShell.set_keyboard_mode(self.window, LayerShell.KeyboardMode.NONE)
        LayerShell.set_namespace(self.window, "hyprvoice-widget")

        provider = Gtk.CssProvider()
        provider.load_from_data(css_for(self.palette))
        Gtk.StyleContext.add_provider_for_display(
            self.window.get_display(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        # Two rows: the device name sits alone on a thin top line, out of the
        # controls' way, so it can be spelled out in full and the waveform keeps
        # the whole width.
        pill = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        pill.add_css_class("pill")
        pill.set_halign(Gtk.Align.CENTER)
        pill.set_size_request(PILL_WIDTH, -1)
        self.window.set_child(pill)

        # Which microphone is live, spelled out: the level meter says whether
        # *something* is heard, never which device is being listened to.
        self.source = Gtk.Label()
        self.source.add_css_class("source")
        self.source.set_xalign(1.0)
        pill.append(self.source)

        # Single source of truth for the row's rhythm: every gap between the
        # mic, the waveform, the timer and the buttons comes from here.
        controls = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=ROW_GAP)
        pill.append(controls)

        # The mic icon *is* the device picker — a separate button would crowd a
        # pill this size, and the icon is where one looks to ask "which mic?".
        self.pinned = pinned_device()  # before draw_mic, which keys the chevron off it
        self.mic = Gtk.DrawingArea(content_width=30, content_height=30)
        self.mic.set_draw_func(self.draw_mic)
        self.picker = Gtk.MenuButton()
        self.picker.add_css_class("micbtn")
        self.picker.set_child(self.mic)
        self.picker.set_popover(Gtk.Popover())
        if self.pinned:
            self.picker.set_sensitive(False)
            self.picker.set_tooltip_text(f"Microphone fixé dans config.toml : {self.pinned}")
        else:
            self.picker.set_tooltip_text("Choisir le microphone")
            # Rebuilt on every open: this desk's main microphone is a wireless
            # headset, so the list genuinely changes between two dictations.
            self.picker.connect("notify::active", self.on_picker_opened)
        self.picker.set_valign(Gtk.Align.CENTER)
        controls.append(self.picker)
        self.refresh_source()

        self.wave = Gtk.DrawingArea(content_width=WAVE_MIN, content_height=38)
        self.wave.set_hexpand(True)
        self.wave.set_valign(Gtk.Align.CENTER)
        self.wave.set_draw_func(self.draw_wave)
        controls.append(self.wave)

        self.state = Gtk.Label(label="0:00")
        self.state.add_css_class("state")
        self.state.set_xalign(1.0)
        self.state.set_valign(Gtk.Align.CENTER)
        controls.append(self.state)

        self.accept = self.button("✓", "ok", self.on_accept, "Valider la dictée")
        controls.append(self.accept)
        controls.append(self.button("✕", "no", self.on_reject, "Annuler la dictée"))

        # The deque is the only thing a column has to reach, so the meter writes
        # straight into it: a push_level of our own held level_now as a second
        # copy of levels[-1], which the picker's reset then failed to clear.
        self.meter = LevelMeter(self.levels.append)
        self.meter.start()
        self.window.present()

        GLib.timeout_add(FRAME_MS, self.on_frame)
        GLib.timeout_add(POLL_MS, self.on_poll)

    def button(self, glyph: str, kind: str, handler, tooltip: str) -> Gtk.Button:
        btn = Gtk.Button(label=glyph)
        btn.add_css_class("act")
        btn.add_css_class(kind)
        btn.set_tooltip_text(tooltip)
        btn.set_valign(Gtk.Align.CENTER)
        btn.connect("clicked", handler)
        return btn

    # ── microphone picker ──────────────────────────────────────────────────
    def on_picker_opened(self, button, _param) -> None:
        if not button.get_active():
            return
        inputs = capture_inputs(pactl_json(["list", "sources"]))
        default = default_source()
        menu = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        if not inputs:
            empty = Gtk.Label(label="aucun microphone détecté")
            empty.add_css_class("srcnone")
            menu.append(empty)
        for name, description in inputs:
            row = Gtk.Button()
            row.add_css_class("srcrow")
            line = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
            tick = Gtk.Label(label="✓" if name == default else "")
            # A pixel width, not width_chars: the tick glyph is wider than the
            # font's average character, so a character-based column leaves the
            # checked row's label indented further than the unchecked ones.
            tick.set_size_request(12, -1)
            tick.set_xalign(0.5)
            line.append(tick)
            line.append(Gtk.Label(label=description, xalign=0.0))
            row.set_child(line)
            if name == default:
                row.add_css_class("on")
            row.connect("clicked", self.on_pick_input, name)
            menu.append(row)
        self.picker.get_popover().set_child(menu)

    def refresh_source(self) -> None:
        """Label the live device, and make sure it is actually audible.

        One `list sources` dump answers both halves — which device is live and
        whether it is muted or zeroed — where asking each question for itself
        fetched the same 20KB of JSON twice. Four pactl execs down to two, and
        none at all spent mutating a healthy microphone: 14ms → 7ms measured, on
        the keypress whose whole job is to put a pill on screen quickly.
        """
        sources = pactl_json(["list", "sources"])
        target = self.pinned or default_source()
        entry = find_source(sources, target)
        description = (entry or {}).get("description") or target or "microphone inconnu"
        self.source.set_text(short_name(description))
        self.source.set_tooltip_text(description)
        if entry is not None:
            ensure_audible(entry)

    def on_pick_input(self, _row, name: str) -> None:
        select_input(name)
        self.refresh_source()
        self.picker.get_popover().popdown()
        # Judge the new device from scratch: without this the meter keeps the
        # old one's verdict, so a working mic stays flagged "micro muet" (and,
        # worse, a dead one inherits a clean bill of health).
        self.meter.heard_signal = False
        self.device_since = GLib.get_monotonic_time()
        self.levels.extend([0.0] * BARS)

    # ── controls ───────────────────────────────────────────────────────────
    def on_accept(self, _btn) -> None:
        """Stop capturing and let hyprvoice transcribe + inject."""
        if self.phase != "listening":
            return
        self.enter_transcribing()
        send_command("toggle")

    def on_reject(self, _btn) -> None:
        send_command("cancel")
        self.close()

    def enter_transcribing(self) -> None:
        self.phase = "transcribing"
        self.meter.stop()
        self.accept.set_sensitive(False)
        self.state.set_text("transcription")
        self.state.remove_css_class("alert")

    def close(self) -> None:
        self.meter.stop()
        app = self.window.get_application()
        self.window.close()
        # Quit outright rather than letting the last-window-closed teardown run
        # its course: while it does, this process still owns the single-instance
        # slot, and a toggle arriving in that window would be answered with a
        # fresh pill instead of starting a new process.
        if app is not None:
            app.quit()

    # ── polling / animation ────────────────────────────────────────────────
    def on_poll(self) -> bool:
        status = daemon_status()
        if status is None or status == "idle":
            self.close()
            return False
        # Mod+D can stop the capture behind our back, so trust the recorder
        # child rather than our own button having been pressed.
        if self.phase == "listening" and not capture_active():
            self.enter_transcribing()
        return True

    def on_frame(self) -> bool:
        if self.phase == "listening":
            if self.muted():
                self.state.set_text("micro muet")
                self.state.add_css_class("alert")
            else:
                elapsed = int(self.elapsed_s())
                self.state.set_text(f"{elapsed // 60}:{elapsed % 60:02d}")
                self.state.remove_css_class("alert")
        self.mic.queue_draw()
        self.wave.queue_draw()
        return True

    # ── drawing ────────────────────────────────────────────────────────────
    def elapsed_s(self) -> float:
        """Seconds since the dictation opened, for the timer and the animations.

        Monotonic, not a counter accumulating FRAME_MS: a hand-integrated clock
        drifts from wall time every time a frame runs late, which left the
        displayed timer and the ripple phase on two different clocks.
        """
        return (GLib.get_monotonic_time() - self.started_us) / 1e6

    def muted(self) -> bool:
        """No non-zero sample since this device came up — i.e. the source is dead.

        Not merely "quiet": one non-zero sample anywhere sets heard_signal for
        good, so a silent room still counts as a working microphone. This catches
        the case a level meter exists for — a hardware-muted headset, which the
        OS still reports as unmuted and recording happily.
        """
        return (
            self.phase == "listening"
            and not self.meter.heard_signal
            and GLib.get_monotonic_time() - self.device_since > SILENT_AFTER_S * 1e6
        )

    def wave_colour(self) -> tuple[float, float, float]:
        return (self.palette["alert"] if self.muted() else self.palette["accent"])[:3]

    def draw_mic(self, _area, cr, width, height) -> None:
        # Everything below is in units of the canvas, not fixed pixels: the glyph
        # was hardcoded for a taller box once and the ripple then drew outside a
        # smaller one, clipped square against its own edges.
        cx, cy = width / 2, height / 2
        u = min(width, height) / 32.0
        r, g, b = self.wave_colour()

        # The "ondulation": rings breathing outward, their reach tied to the
        # live level so a quiet room stays visibly calm.
        if self.phase == "listening":
            drive = 0.25 + 0.75 * self.levels[-1]
            near, far = 8.0 * u, min(width, height) / 2 - 1.0
            for k in range(3):
                t = (self.elapsed_s() / 1.7 + k / 3.0) % 1.0
                cr.set_source_rgba(r, g, b, (1.0 - t) * 0.42 * drive)
                cr.set_line_width(1.2 * u)
                cr.arc(cx, cy, near + (far - near) * t, 0, 2 * math.pi)
                cr.stroke()

        ink = self.palette["alert"] if self.muted() else self.palette["ink"]
        cr.set_source_rgba(*ink)
        # Capsule body.
        body_w, body_h, top = 7.0 * u, 11.5 * u, cy - 9.0 * u
        cr.new_sub_path()
        cr.arc(cx, top + body_w / 2, body_w / 2, math.pi, 0)
        cr.arc(cx, top + body_h - body_w / 2, body_w / 2, 0, math.pi)
        cr.close_path()
        cr.fill()
        # Cradle + stem.
        cr.set_line_width(1.4 * u)
        cr.arc(cx, cy - 1.0 * u, 6.2 * u, 0.15 * math.pi, 0.85 * math.pi)
        cr.stroke()
        cr.move_to(cx, cy + 5.2 * u)
        cr.line_to(cx, cy + 8.2 * u)
        cr.stroke()

        # A chevron so the icon reads as a control rather than as decoration;
        # dropped when the device is pinned and there is nothing to open.
        if not self.pinned:
            cr.set_source_rgba(*self.palette["dim"])
            cr.set_line_width(1.2 * u)
            cr.move_to(cx + 5.6 * u, cy + 6.4 * u)
            cr.line_to(cx + 7.6 * u, cy + 8.4 * u)
            cr.line_to(cx + 9.6 * u, cy + 6.4 * u)
            cr.stroke()

    def draw_wave(self, _area, cr, width, height) -> None:
        r, g, b = self.wave_colour()
        cy = height / 2
        slot = width / BARS
        bar_w = max(2.0, slot * 0.46)
        cr.set_line_width(bar_w)
        cr.set_line_cap(1)  # cairo.LINE_CAP_ROUND, without importing cairo

        for i in range(BARS):
            if self.phase == "listening":
                level = self.levels[i]
            else:
                # A travelling swell stands in for the frozen waveform while
                # the API call is out, so the pill still reads as busy.
                head = (self.elapsed_s() * 1.5) % 1.0 * (BARS + 12) - 6
                level = 0.10 + 0.42 * math.exp(-(((i - head) / 4.0) ** 2))
            bar_h = max(1.5, level * (height - 8))
            x = slot * (i + 0.5)
            # Oldest bars sit back, newest lead — the trail that makes the
            # motion read as flowing rather than as 44 independent meters.
            fade = 0.30 + 0.70 * (i / (BARS - 1))
            cr.set_source_rgba(r, g, b, fade)
            cr.move_to(x, cy - bar_h / 2)
            cr.line_to(x, cy + bar_h / 2)
            cr.stroke()


class WidgetApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="dev.dotfiles.HyprvoiceWidget")
        self.overlay: Overlay | None = None

    def do_activate(self) -> None:
        # Single-instance: a second Mod+D reaches the running overlay here
        # instead of stacking another one.
        if self.overlay and self.overlay.window.get_visible():
            self.overlay.window.present()
            return
        self.overlay = Overlay(self)


def main() -> int:
    status = daemon_status()
    if status is None:
        print("hyprvoice daemon is not running", file=sys.stderr)
        return 1
    if status == "idle":
        return 0  # this toggle ended a dictation — nothing to show
    return WidgetApp().run(None)


if __name__ == "__main__":
    sys.exit(main())
