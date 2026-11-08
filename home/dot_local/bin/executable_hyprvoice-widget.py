#!/usr/bin/env python3

# Hyprvoice dictation overlay — a layer-shell pill showing the live microphone
# level while hyprvoice records, plus pointer controls (language and source
# chips, pause, validate / cancel) so a dictation can be driven without
# reaching for Mod+D.
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
import re
import signal
import socket
import struct
import subprocess
import sys
import tomllib
from collections import deque
from functools import cache
from pathlib import Path

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

from gi.repository import Gio, GLib, Gtk, Pango
from gi.repository import Gtk4LayerShell as LayerShell

CACHE = Path.home() / ".cache" / "hyprvoice"
SOCKET_PATH = CACHE / "control.sock"
PID_PATH = CACHE / "hyprvoice.pid"
CONFIG_PATH = Path.home() / ".config" / "hyprvoice" / "config.toml"

BARS = 36  # waveform columns, newest on the right
BAR_MS = 45  # audio per column
POLL_MS = 120  # hyprvoice status / phase poll
FRAME_MS = 33  # ~30 fps; the ripple reads smooth and the pill is tiny
SILENT_AFTER_S = 2.0  # flag a digitally-silent source after this long
FLOOR_DB = -55.0  # quietest level the meter still shows movement for
ROW_GAP = 8  # one gap value for every element in the control row
PILL_WIDTH = 410  # fixed, so the waveform can absorb every width change
WAVE_MIN = 140  # floor for the waveform; hexpand gives it whatever is left
CONTROL = 28  # mic, validate and cancel: one size for every round control
# Transparent room around the pill for its drop shadow: the layer surface is
# sized to its content, so a shadow with nowhere to fall is clipped to nothing.
# The bottom gets more, the shadow is offset downward.
SHADOW_ROOM = (14, 18, 22, 18)  # top, right, bottom, left
PILL_BOTTOM = 90  # pill edge to screen bottom, shadow room included below

# Dictation languages the chip offers, in menu order. dictation-lang owns the
# codes; anything it does not recognise reads as auto.
LANGUAGES = {"auto": "Auto (détection)", "fr": "Français", "en": "English"}
CAPTURE_GRACE_S = 1.0  # pw-record is not up the instant a toggle returns
WARN_BEFORE_S = 60  # the timer turns orange this long before the daemon gives up

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
# eleven other files (waybar, swaync, swayosd, wlogout, yazi, theme.lua),
# and a flavour tweak has to be able to find this one by grepping for the same
# string as the rest. Cairo wants 0..1 floats, so the conversion happens once at
# import rather than being baked into the source.
def rgba(colour: str, alpha: float = 1.0) -> tuple[float, float, float, float]:
    r, g, b = (int(colour[i : i + 2], 16) / 255.0 for i in (1, 3, 5))
    return r, g, b, alpha


DARK = {  # Catppuccin Mocha
    "bg": rgba("#1e1e2e", 0.94),  # base
    "rim": rgba("#cdd6f4", 0.14),
    "ink": rgba("#cdd6f4"),  # text
    "dim": rgba("#a6adc8"),  # subtext0
    "accent": rgba("#cba6f7"),  # mauve
    "alert": rgba("#f38ba8"),  # red
    "warn": rgba("#fab387"),  # peach
    "shadow": rgba("#11111b", 0.55),  # crust
}
LIGHT = {  # Catppuccin Latte
    "bg": rgba("#eff1f5", 0.96),  # base
    "rim": rgba("#4c4f69", 0.12),
    "ink": rgba("#4c4f69"),
    "dim": rgba("#6c6f85"),
    "accent": rgba("#8839ef"),
    "alert": rgba("#d20f39"),
    "warn": rgba("#fe640b"),
    "shadow": rgba("#4c4f69", 0.18),
}

CSS = """
/* One tint ladder for every control, so they read as one family: 0.06 at
 * rest, 0.12 hovered, 0.18 open. Validate and a pinned language use the accent
 * on the same ladder, everything else the text colour. */
window.hv {{ background: transparent; }}
box.pill {{
  background: rgba({bg_r}, {bg_g}, {bg_b}, {bg_a});
  border: 1px solid rgba({rim_r}, {rim_g}, {rim_b}, {rim_a});
  /* A rounded rectangle, not a stadium: on two rows a full-radius end is a
   * 40px half-circle that squeezes the top line's ends into the curve. */
  border-radius: 20px;
  padding: 8px 12px;
  box-shadow: 0 6px 18px rgba({shadow_r}, {shadow_g}, {shadow_b}, {shadow_a}),
              0 1px 3px rgba({shadow_r}, {shadow_g}, {shadow_b}, {shadow_a});
}}
/* The timer only: status words go on the top line, so this column keeps one
 * width and the waveform never jumps. Tabular figures stop 1:11 from being
 * narrower than 0:08. */
label.timer {{
  color: rgb({dim_r}, {dim_g}, {dim_b});
  font-size: 12px;
  font-feature-settings: "tnum";
  min-width: 34px;
}}
label.source,
label.status {{ font-size: 11px; }}
label.status {{ color: rgb({dim_r}, {dim_g}, {dim_b}); }}
/* Paused: the frozen timer pulses, the one moving thing on a held pill. */
label.timer.paused {{
  color: rgb({accent_r}, {accent_g}, {accent_b});
  animation: hv-pulse 1.4s ease-in-out infinite;
}}
/* Near the daemon's deadline; after .paused so it wins the colour while a
 * paused pill keeps its pulse — the deadline runs through a pause. */
label.timer.warn {{ color: rgb({warn_r}, {warn_g}, {warn_b}); }}
@keyframes hv-pulse {{ 50% {{ opacity: 0.35; }} }}
label.lang {{
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.6px;
}}
button.act,
button.micbtn,
menubutton.langbtn > button,
menubutton.srcbtn > button {{
  padding: 0;
  margin: 0;
  border: none;
  outline: none;
  box-shadow: none;
  background-image: none;
  border-radius: 999px;
  transition: background 120ms ease, color 120ms ease, opacity 120ms ease;
}}
/* GtkMenuButton's CSS node is `menubutton`, wrapping a `button` child — a
 * `button.langbtn` selector matches neither, so the platform theme's raised
 * button showed through as a dark slab. The outer node is flattened too. */
menubutton.langbtn,
menubutton.srcbtn {{
  padding: 0;
  margin: 0;
  background: none;
  box-shadow: none;
}}
button.act,
button.micbtn {{
  min-width: {control}px;
  min-height: {control}px;
}}
button.act.no,
button.micbtn,
menubutton.langbtn > button,
menubutton.srcbtn > button {{
  background-color: rgba({ink_r}, {ink_g}, {ink_b}, 0.06);
  color: rgb({dim_r}, {dim_g}, {dim_b});
}}
button.act.no:hover,
button.micbtn:hover,
menubutton.langbtn > button:hover,
menubutton.srcbtn > button:hover {{ background-color: rgba({ink_r}, {ink_g}, {ink_b}, 0.12); }}
menubutton.langbtn > button:checked,
menubutton.srcbtn > button:checked {{ background-color: rgba({ink_r}, {ink_g}, {ink_b}, 0.18); }}
button.act.no:hover {{ color: rgb({alert_r}, {alert_g}, {alert_b}); }}
button.act.ok,
button.micbtn.paused,
menubutton.langbtn.pinned > button {{
  background-color: rgba({accent_r}, {accent_g}, {accent_b}, 0.16);
  color: rgb({accent_r}, {accent_g}, {accent_b});
}}
button.act.ok:hover,
button.micbtn.paused:hover,
menubutton.langbtn.pinned > button:hover {{
  background-color: rgba({accent_r}, {accent_g}, {accent_b}, 0.26);
}}
menubutton.langbtn.pinned > button:checked {{
  background-color: rgba({accent_r}, {accent_g}, {accent_b}, 0.32);
}}
/* A dead source: the chip turns red but stays a chip — this is exactly when
 * picking another microphone is the fix. */
menubutton.srcbtn.alert > button {{
  background-color: rgba({alert_r}, {alert_g}, {alert_b}, 0.14);
  color: rgb({alert_r}, {alert_g}, {alert_b});
}}
/* Same height as the top line's text plus air, so the chips read as controls
 * without making the line taller than the text needs. */
menubutton.langbtn > button,
menubutton.srcbtn > button {{
  min-height: 20px;
  min-width: 0;
  padding: 0 8px;
}}
button.act:disabled,
menubutton.langbtn > button:disabled,
menubutton.srcbtn > button:disabled {{ opacity: 0.4; }}
/* Opaque, unlike the pill: a menu always opens over the pill here, and
 * through a translucent one the mic glyph showed under the first row. */
popover > contents {{
  background: rgb({bg_r}, {bg_g}, {bg_b});
  border: 1px solid rgba({rim_r}, {rim_g}, {rim_b}, {rim_a});
  border-radius: 12px;
  padding: 4px;
  box-shadow: 0 4px 12px rgba({shadow_r}, {shadow_g}, {shadow_b}, {shadow_a});
}}
/* The theme's button gradient and inset shadow drew a separator line under
 * every row; all of it goes. Radius 8 = the popover's 12 minus its padding. */
button.srcrow {{
  border: none;
  outline: none;
  box-shadow: none;
  background: transparent;
  background-image: none;
  border-radius: 8px;
  min-height: 0;
  padding: 6px 10px;
  color: rgb({ink_r}, {ink_g}, {ink_b});
  font-size: 12px;
  transition: background 120ms ease;
}}
button.srcrow:hover {{ background: rgba({ink_r}, {ink_g}, {ink_b}, 0.10); }}
button.srcrow.on {{
  color: rgb({accent_r}, {accent_g}, {accent_b});
  background: rgba({accent_r}, {accent_g}, {accent_b}, 0.10);
}}
label.srcnone,
label.menunote {{
  color: rgb({dim_r}, {dim_g}, {dim_b});
  padding: 6px 10px;
}}
label.srcnone {{ font-size: 12px; }}
label.menunote {{
  font-size: 11px;
  border-top: 1px solid rgba({rim_r}, {rim_g}, {rim_b}, {rim_a});
  margin-top: 4px;
}}
"""

def css_for(palette: dict) -> bytes:
    fields = {}
    for name, (r, g, b, a) in palette.items():
        fields[f"{name}_r"] = round(r * 255)
        fields[f"{name}_g"] = round(g * 255)
        fields[f"{name}_b"] = round(b * 255)
        fields[f"{name}_a"] = a
    return CSS.format(control=CONTROL, **fields).encode()


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


def recorder_pid() -> int | None:
    """The daemon's live pw-record child, or None once capture has ended.

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
        return None
    for child in children:
        try:
            stat = Path(f"/proc/{child}/stat").read_text()
        except OSError:
            continue
        # comm is parenthesised and may itself contain spaces or parens, so
        # split on the *last* ')': what follows is the single-letter state.
        name = stat[stat.find("(") + 1 : stat.rfind(")")]
        tail = stat[stat.rfind(")") + 1 :].split()
        # A stopped one ("T") is ours, paused: still the live recorder.
        if name == "pw-record" and tail and tail[0] != "Z":
            return int(child)
    return None


def signal_recorder(signum: int) -> bool:
    """Send `signum` to the daemon's recorder; False when there is none.

    This is the whole pause mechanism. hyprvoice has no pause command, and
    muting the stream instead records silence, on which Whisper invents text
    ("Merci d'avoir regardé cette vidéo !" from a 60s gap, measured against
    the same Groq model). A stopped pw-record records *nothing*: PipeWire
    drops the frames it cannot deliver and resumes live on SIGCONT — measured
    with a clock signal on a null sink, a 40s stop left no gap, no silence and
    no stale audio in the file.
    """
    pid = recorder_pid()
    if pid is None:
        return False
    try:
        os.kill(pid, signum)
    except OSError:
        return False
    return True


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


@cache
def hyprvoice_config() -> dict:
    """The daemon's config, parsed once for the settings read out of it."""
    try:
        with CONFIG_PATH.open("rb") as handle:
            return tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError):
        return {}


def pinned_device() -> str | None:
    """hyprvoice's `[recording] device`, when it names one.

    Empty (the shipped default) means "follow the PipeWire default source",
    which is what makes the picker below effective. A pinned device overrides
    it, so the picker says so instead of quietly doing nothing.
    """
    return hyprvoice_config().get("recording", {}).get("device", "") or None


def recording_limit_s() -> float:
    """hyprvoice's `[recording] timeout` (a Go duration), in seconds.

    The daemon's deadline for the whole clip: it runs on the wall clock from the
    toggle, pauses included, and covers transcription and the LLM pass too.
    Reaching it loses the clip without a word — pipeline.go returns on the
    expired context and the final transcribe then fails on that same context.
    """
    raw = str(hyprvoice_config().get("recording", {}).get("timeout", ""))
    units = {"h": 3600, "m": 60, "s": 1, "ms": 0.001}
    total = sum(
        float(n) * units[u] for n, u in re.findall(r"(\d+(?:\.\d+)?)(ms|h|m|s)", raw)
    )
    return total or 300.0  # hyprvoice's own default


def dictation_language() -> str:
    """hyprvoice's `[transcription] language`, as a LANGUAGES key.

    Shown because it is the one setting that can silently *translate* a
    dictation: Whisper writes in whatever language it is given, so a pinned "fr"
    turns an English clip into French prose rather than into mis-spelled
    English. Empty means auto-detect.

    Changing it is not done here: dictation-lang owns the write (state file,
    reload wait, the v1.0.2 restart workaround). And it cannot happen under a
    live recording — the daemon answers a config change by tearing the pipeline
    down — so the chip restarts the clip around it, see Overlay.on_pick_lang.
    """
    code = hyprvoice_config().get("transcription", {}).get("language", "")
    return code if code in LANGUAGES else "auto"


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


def menu_popover() -> Gtk.Popover:
    """A popover without the arrow: the menu covers the pill it belongs to
    (Hyprland opens it downward whatever GTK asks), so an arrow only points at
    the control it is hiding."""
    popover = Gtk.Popover()
    popover.set_has_arrow(False)
    return popover


def draw_glyph(area, cr, width, height, kind: str) -> None:
    """✓ or ✕ as strokes on a 28px grid, in the button's CSS colour."""
    colour = area.get_color()
    cr.set_source_rgba(colour.red, colour.green, colour.blue, colour.alpha)
    u = min(width, height) / 28.0
    cr.translate((width - 28.0 * u) / 2, (height - 28.0 * u) / 2)
    cr.set_line_width(2.0 * u)
    cr.set_line_cap(1)  # cairo.LINE_CAP_ROUND
    cr.set_line_join(1)  # cairo.LINE_JOIN_ROUND
    if kind == "ok":
        # Optical centre, not geometric: a check's mass sits low-left.
        cr.move_to(9.0 * u, 14.5 * u)
        cr.line_to(12.5 * u, 18.0 * u)
        cr.line_to(19.0 * u, 10.5 * u)
    else:
        cr.move_to(10.0 * u, 10.0 * u)
        cr.line_to(18.0 * u, 18.0 * u)
        cr.move_to(18.0 * u, 10.0 * u)
        cr.line_to(10.0 * u, 18.0 * u)
    cr.stroke()


def menu_row(text: str, on: bool, handler, arg) -> Gtk.Button:
    """One popover row with a tick column, shared by the mic and language menus."""
    row = Gtk.Button()
    row.add_css_class("srcrow")
    line = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
    tick = Gtk.Label(label="✓" if on else "")
    # A pixel width, not width_chars: the tick glyph is wider than the
    # font's average character, so a character-based column leaves the
    # checked row's label indented further than the unchecked ones.
    tick.set_size_request(12, -1)
    tick.set_xalign(0.5)
    line.append(tick)
    line.append(Gtk.Label(label=text, xalign=0.0))
    row.set_child(line)
    if on:
        row.add_css_class("on")
    row.connect("clicked", handler, arg)
    return row


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
        self.phase = "listening"  # listening | switching | transcribing
        self.started_us = GLib.get_monotonic_time()
        self.warn_at_s = recording_limit_s() - WARN_BEFORE_S
        # When this *device* started being listened to, which the picker resets
        # and the dictation timer does not — the two questions came apart the
        # moment a mic could be swapped mid-sentence.
        self.device_since = self.started_us

        self.window = Gtk.ApplicationWindow(application=app)
        self.window.add_css_class("hv")
        LayerShell.init_for_window(self.window)
        LayerShell.set_layer(self.window, LayerShell.Layer.OVERLAY)
        LayerShell.set_anchor(self.window, LayerShell.Edge.BOTTOM, True)
        LayerShell.set_margin(self.window, LayerShell.Edge.BOTTOM, PILL_BOTTOM - SHADOW_ROOM[2])
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
        pill = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        pill.add_css_class("pill")
        pill.set_halign(Gtk.Align.CENTER)
        pill.set_size_request(PILL_WIDTH, -1)
        top, right, bottom, left = SHADOW_ROOM
        pill.set_margin_top(top)
        pill.set_margin_end(right)
        pill.set_margin_bottom(bottom)
        pill.set_margin_start(left)
        self.window.set_child(pill)

        # The thin top line carries the two things that decide what comes out of
        # a dictation and are otherwise invisible while speaking: the language
        # Whisper is pinned to, on the left, and the live microphone on the
        # right — or, in its place, what the pill is busy with. Both are chips
        # opening the same kind of menu. Spacing 8 is only the floor for when a
        # long device name meets the language chip.
        head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        pill.append(head)

        # Each chip is its own picker: the label is where one looks to ask
        # "which language?" / "which microphone?".
        self.lang = dictation_language()
        self.lang_chip = Gtk.Label()
        self.lang_chip.add_css_class("lang")
        self.lang_btn = Gtk.MenuButton()
        self.lang_btn.add_css_class("langbtn")
        self.lang_btn.set_child(self.lang_chip)
        self.lang_btn.set_popover(menu_popover())
        self.lang_btn.set_tooltip_text("Langue de dictée")
        self.lang_btn.set_valign(Gtk.Align.CENTER)
        self.lang_btn.set_cursor_from_name("pointer")
        self.lang_btn.connect("notify::active", self.on_lang_opened)
        head.append(self.lang_btn)
        self.show_lang()

        # Which microphone is live, spelled out: the level meter says whether
        # *something* is heard, never which device is being listened to.
        # Ellipsized, because the pill's width is a minimum, not a cap: a long
        # headset name would otherwise widen the whole surface. The tooltip
        # keeps the full name.
        self.device = ""
        self.pinned = pinned_device()
        self.source = Gtk.Label()
        self.source.add_css_class("source")
        self.source.set_ellipsize(Pango.EllipsizeMode.END)
        self.source.set_max_width_chars(34)
        self.src_btn = Gtk.MenuButton()
        self.src_btn.add_css_class("srcbtn")
        self.src_btn.set_child(self.source)
        self.src_btn.set_popover(menu_popover())
        self.src_btn.set_hexpand(True)
        self.src_btn.set_halign(Gtk.Align.END)
        self.src_btn.set_valign(Gtk.Align.CENTER)
        if self.pinned:
            self.src_btn.set_sensitive(False)
        else:
            self.src_btn.set_cursor_from_name("pointer")
            # Rebuilt on every open: this desk's main microphone is a wireless
            # headset, so the list genuinely changes between two dictations.
            self.src_btn.connect("notify::active", self.on_source_opened)
        head.append(self.src_btn)
        # What the pill is busy with, in the source chip's place: a microphone
        # cannot be changed while transcribing or restarting anyway.
        self.status = Gtk.Label()
        self.status.add_css_class("status")
        self.status.set_hexpand(True)
        self.status.set_xalign(1.0)
        self.status.set_visible(False)
        head.append(self.status)
        self.refresh_source()

        # Single source of truth for the row's rhythm: every gap between the
        # mic, the waveform, the timer and the buttons comes from here.
        controls = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=ROW_GAP)
        pill.append(controls)

        # The mic icon shows the signal (it breathes with the level, and turns
        # red on a dead source) and is the pause toggle, the way a call app's
        # mic button is.
        self.paused = False
        self.paused_us = 0  # paused time already banked, for the timer
        self.paused_since = 0
        self.mic = Gtk.DrawingArea(content_width=CONTROL, content_height=CONTROL)
        self.mic.set_draw_func(self.draw_mic)
        self.mic_btn = Gtk.Button()
        self.mic_btn.add_css_class("micbtn")
        self.mic_btn.set_child(self.mic)
        self.mic_btn.set_tooltip_text("Mettre en pause")
        self.mic_btn.set_cursor_from_name("pointer")
        self.mic_btn.set_valign(Gtk.Align.CENTER)
        self.mic_btn.connect("clicked", self.on_pause)
        controls.append(self.mic_btn)

        self.wave = Gtk.DrawingArea(content_width=WAVE_MIN, content_height=CONTROL)
        self.wave.set_hexpand(True)
        self.wave.set_valign(Gtk.Align.CENTER)
        self.wave.set_draw_func(self.draw_wave)
        controls.append(self.wave)

        self.timer = Gtk.Label(label="0:00")
        self.timer.add_css_class("timer")
        self.timer.set_xalign(1.0)
        self.timer.set_valign(Gtk.Align.CENTER)
        controls.append(self.timer)

        # The pair sits closer than the row gap: they are one decision.
        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        actions.set_valign(Gtk.Align.CENTER)
        controls.append(actions)
        self.accept = self.button("ok", self.on_accept, "Valider la dictée")
        actions.append(self.accept)
        actions.append(self.button("no", self.on_reject, "Annuler la dictée"))

        # The deque is the only thing a column has to reach, so the meter writes
        # straight into it: a push_level of our own held level_now as a second
        # copy of levels[-1], which the picker's reset then failed to clear.
        self.meter = LevelMeter(self.on_level)
        self.meter.start()
        self.show_head()  # needs the meter: muted() reads its verdict
        self.window.present()

        GLib.timeout_add(FRAME_MS, self.on_frame)
        GLib.timeout_add(POLL_MS, self.on_poll)

    def button(self, kind: str, handler, tooltip: str) -> Gtk.Button:
        """A round control whose ✓ / ✕ is drawn, not typed.

        Font glyphs sat off-centre and at different weights (✓ thinner and
        lower than ✕); strokes on a fixed grid are centred by construction and
        take their colour from CSS, so hover states still apply.
        """
        glyph = Gtk.DrawingArea(content_width=CONTROL, content_height=CONTROL)
        glyph.set_draw_func(draw_glyph, kind)
        btn = Gtk.Button()
        btn.set_child(glyph)
        btn.add_css_class("act")
        btn.add_css_class(kind)
        btn.set_tooltip_text(tooltip)
        btn.set_cursor_from_name("pointer")
        btn.connect("clicked", handler)
        # A CSS colour change does not repaint a DrawingArea on its own.
        btn.connect("state-flags-changed", lambda *_: glyph.queue_draw())
        return btn

    # ── microphone picker ──────────────────────────────────────────────────
    def on_source_opened(self, button, _param) -> None:
        if not button.get_active():
            return
        inputs = capture_inputs(pactl_json(["list", "sources"]))
        default = default_source()
        menu = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        if not inputs:
            empty = Gtk.Label(label="Aucun microphone détecté")
            empty.add_css_class("srcnone")
            menu.append(empty)
        for name, description in inputs:
            menu.append(menu_row(description, name == default, self.on_pick_input, name))
        self.src_btn.get_popover().set_child(menu)

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
        description = (entry or {}).get("description") or target
        description = description or "Microphone inconnu"
        self.device = short_name(description)
        self.source.set_text(self.device)
        if self.pinned:
            description = f"Microphone fixé dans config.toml : {description}"
        self.src_btn.set_tooltip_text(description)
        if entry is not None:
            ensure_audible(entry)

    def on_pick_input(self, _row, name: str) -> None:
        select_input(name)
        self.refresh_source()
        self.src_btn.get_popover().popdown()
        # Judge the new device from scratch: without this the meter keeps the
        # old one's verdict, so a working mic stays flagged "micro muet" (and,
        # worse, a dead one inherits a clean bill of health).
        self.meter.heard_signal = False
        self.device_since = GLib.get_monotonic_time()
        self.levels.extend([0.0] * BARS)

    # ── pause ──────────────────────────────────────────────────────────────
    def on_level(self, level: float) -> None:
        # Frozen while paused: the meter's own stream keeps hearing the room,
        # but what it hears then is not going into the dictation.
        if not self.paused:
            self.levels.append(level)

    def on_pause(self, _btn) -> None:
        if self.phase != "listening":
            return
        if self.paused:
            self.resume()
        elif signal_recorder(signal.SIGSTOP):
            self.paused = True
            self.paused_since = GLib.get_monotonic_time()
            self.mic_btn.add_css_class("paused")
            self.mic_btn.set_tooltip_text("Reprendre")
            self.timer.add_css_class("paused")

    def resume(self) -> None:
        """Wake the recorder. Called before anything that ends or restarts the
        clip, since a stopped pw-record sits on the daemon's stop signal until
        it is continued — toggle-dictation.sh does the same for Mod+D."""
        if not self.paused:
            return
        signal_recorder(signal.SIGCONT)
        self.paused = False
        self.paused_us += GLib.get_monotonic_time() - self.paused_since
        self.mic_btn.remove_css_class("paused")
        self.mic_btn.set_tooltip_text("Mettre en pause")
        self.timer.remove_css_class("paused")

    # ── language picker ────────────────────────────────────────────────────
    def show_lang(self) -> None:
        # Auto-detect is the quiet case, in the grey of everything else; a
        # pinned language takes the accent, the one place a stuck "EN" must
        # show — it means the clip is *written* in that language whatever is
        # spoken into it.
        self.lang_chip.set_text(self.lang.upper())
        if self.lang == "auto":
            self.lang_btn.remove_css_class("pinned")
        else:
            self.lang_btn.add_css_class("pinned")

    def on_lang_opened(self, button, _param) -> None:
        if not button.get_active():
            return
        menu = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        for code, name in LANGUAGES.items():
            menu.append(menu_row(name, code == self.lang, self.on_pick_lang, code))
        # Said before the click, not discovered after it: picking discards what
        # has been dictated so far (see on_pick_lang).
        note = Gtk.Label(label="Changer relance l'enregistrement à zéro", xalign=0.0)
        note.add_css_class("menunote")
        menu.append(note)
        button.get_popover().set_child(menu)

    def on_pick_lang(self, _row, code: str) -> None:
        """Restart the clip in `code`: cancel, rewrite the config, toggle again.

        The restart is the price of the daemon, not a choice: the pipeline is
        built from config.toml at toggle time, and a config reload tears a live
        one down. What was said so far is dropped — the chip is for the first
        second of a dictation, before there is much to lose.
        """
        self.lang_btn.get_popover().popdown()
        if code == self.lang or self.phase != "listening":
            return
        self.resume()
        self.phase = "switching"
        self.accept.set_sensitive(False)
        self.lang_btn.set_sensitive(False)
        send_command("cancel")
        # dictation-lang waits out the cancel itself (it owns the daemon-state
        # checks), then the reload. Async: ~1s, and the pill animates through it.
        try:
            self.lang_proc = Gio.Subprocess.new(
                ["dictation-lang", "set", code], Gio.SubprocessFlags.NONE
            )
        except GLib.Error:
            self.restart_capture()
            return
        self.lang_proc.wait_async(None, lambda *_: self.restart_capture())

    def restart_capture(self) -> None:
        # Re-read rather than trust the pick: a refused or failed switch leaves
        # the old language in the file, and the chip must say what will be used.
        hyprvoice_config.cache_clear()
        self.lang = dictation_language()
        self.show_lang()
        self.lang_btn.set_sensitive(True)
        # Only our own idle daemon gets toggled: a Mod+D that landed meanwhile
        # already started a clip, and toggling would stop it.
        if daemon_status() != "idle":
            self.close()
            return
        send_command("toggle")
        self.phase = "listening"
        self.accept.set_sensitive(True)
        self.started_us = self.device_since = GLib.get_monotonic_time()
        self.warn_at_s = recording_limit_s() - WARN_BEFORE_S
        self.paused_us = 0
        self.meter.heard_signal = False
        self.levels.extend([0.0] * BARS)

    # ── controls ───────────────────────────────────────────────────────────
    def on_accept(self, _btn) -> None:
        """Stop capturing and let hyprvoice transcribe + inject."""
        if self.phase != "listening":
            return
        self.resume()
        self.enter_transcribing()
        send_command("toggle")

    def on_reject(self, _btn) -> None:
        self.resume()
        send_command("cancel")
        self.close()

    def enter_transcribing(self) -> None:
        # Mod+D wakes a paused recorder behind our back before stopping it, so
        # the pause can end without on_pause: settle it here, on every path.
        self.resume()
        self.phase = "transcribing"
        self.meter.stop()
        self.accept.set_sensitive(False)
        self.mic_btn.set_sensitive(False)
        # A pick now would be ignored (on_pick_lang only acts while listening).
        self.lang_btn.set_sensitive(False)

    def close(self) -> None:
        self.resume()
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
        # Mid-switch the daemon is idle (or even restarting) on purpose.
        if self.phase == "switching":
            return True
        status = daemon_status()
        if status is None or status == "idle":
            self.close()
            return False
        # Mod+D can stop the capture behind our back, so trust the recorder
        # child rather than our own button having been pressed.
        if (
            self.phase == "listening"
            and self.elapsed_s() > CAPTURE_GRACE_S
            and recorder_pid() is None
        ):
            self.enter_transcribing()
        return True

    def show_head(self) -> None:
        """The top line's right end: the source chip, or what the pill is busy with.

        Status words live here rather than in the timer's slot, so the control
        row keeps one geometry in every state. A dead source keeps its chip,
        in red: that is when switching microphones is the fix. set_text and
        set_visible on an unchanged value are no-ops in GTK, which keeps this
        cheap at the frame rate.
        """
        busy = {"switching": "Redémarrage…", "transcribing": "Transcription…"}
        text = busy.get(self.phase)
        self.status.set_text(text or "")
        self.status.set_visible(text is not None)
        self.src_btn.set_visible(text is None)
        alerted = self.src_btn.has_css_class("alert")
        if self.muted() and not alerted:
            self.src_btn.add_css_class("alert")
            self.src_btn.set_tooltip_text("Aucun signal — choisir un autre microphone")
        elif alerted and not self.muted():
            self.src_btn.remove_css_class("alert")
            self.refresh_source()  # puts the device tooltip back

    def on_frame(self) -> bool:
        if self.phase == "listening" and not self.paused:
            spoken = int(self.elapsed_s() - self.paused_us / 1e6)
            self.timer.set_text(f"{spoken // 60}:{spoken % 60:02d}")
        # Wall clock, not the spoken time shown: the daemon's deadline counts
        # the pauses too, and still runs while the clip is transcribed.
        near = self.phase != "switching" and self.elapsed_s() > self.warn_at_s
        if near != self.timer.has_css_class("warn"):
            if near:
                self.timer.add_css_class("warn")
                self.timer.set_tooltip_text("Limite proche — valider avant la coupure")
            else:
                self.timer.remove_css_class("warn")
                self.timer.set_tooltip_text(None)
        self.show_head()
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
            and not self.paused
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
        # live level so a quiet room stays visibly calm. Two, and faint: the
        # button's own tint is already a circle, and the waveform carries the
        # motion.
        if self.phase == "listening" and not self.paused:
            drive = 0.25 + 0.75 * self.levels[-1]
            near, far = 8.0 * u, min(width, height) / 2 - 1.0
            for k in range(2):
                t = (self.elapsed_s() / 1.7 + k / 2.0) % 1.0
                cr.set_source_rgba(r, g, b, (1.0 - t) * 0.30 * drive)
                cr.set_line_width(1.2 * u)
                cr.arc(cx, cy, near + (far - near) * t, 0, 2 * math.pi)
                cr.stroke()

        if self.muted():
            ink = self.palette["alert"]
        elif self.paused:
            ink = self.palette["accent"]
        else:
            ink = self.palette["ink"]
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
        # Paused: the classic muted-mic slash.
        if self.paused:
            cr.set_line_width(1.6 * u)
            cr.set_line_cap(1)  # cairo.LINE_CAP_ROUND
            cr.move_to(cx - 7.5 * u, cy - 9.5 * u)
            cr.line_to(cx + 7.5 * u, cy + 8.5 * u)
            cr.stroke()

    def draw_wave(self, _area, cr, width, height) -> None:
        r, g, b = self.wave_colour()
        cy = height / 2
        slot = width / BARS
        # 3px bars on whole-pixel centres (+0.5: an odd width straddles the
        # pixel grid otherwise), or antialiasing makes equal bars look unequal.
        bar_w = 3.0
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
            bar_h = max(0.5, level * (height - 4 - bar_w))
            x = math.floor(slot * (i + 0.5)) + 0.5
            # Oldest bars sit back, newest lead — the trail that makes the
            # motion read as flowing rather than as independent meters.
            fade = 0.40 + 0.60 * (i / (BARS - 1))
            if self.paused:
                fade *= 0.45  # held, not live
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
