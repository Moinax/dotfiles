import { capture, captureLines } from "./shell";

/**
 * The desktop surfaces the launcher reads: audio sinks and open windows.
 *
 * This file used to also carry state readers for dark mode, caffeine and
 * tailscale, feeding a Quick Actions command that mirrored ten toggles which
 * all already had a keybind. That command was dropped — its rofi ancestor had
 * never been wired into any `modi` list either, so it was unreachable for its
 * whole life — and the readers went with it. Waybar's modules are where that
 * state is read now, from the same files.
 */

export type Sink = { name: string; description: string; isDefault: boolean };

/**
 * Audio sinks, from pactl's JSON output.
 *
 * toggle-audio-switch.sh scrapes `wpctl status` with sed and grep over a
 * box-drawing table, then matches the chosen row back by substring — which
 * picks the wrong sink as soon as one description contains another. `pactl -f
 * json` hands over names and descriptions as data, so the row the user picked
 * is the row that gets set.
 */
export async function sinks(): Promise<Sink[]> {
  const [raw, def] = await Promise.all([
    capture("pactl", ["-f", "json", "list", "sinks"]),
    capture("pactl", ["get-default-sink"]),
  ]);
  const defaultName = def.trim();
  const parsed = JSON.parse(raw) as Array<{ name: string; description?: string; properties?: Record<string, string> }>;
  return parsed.map((sink) => ({
    name: sink.name,
    description: sink.description || sink.properties?.["device.description"] || sink.name,
    isDefault: sink.name === defaultName,
  }));
}

export async function setDefaultSink(name: string): Promise<void> {
  await capture("pactl", ["set-default-sink", name]);
}

export type HyprWindow = {
  address: string;
  pid: number;
  class: string;
  title: string;
  workspace: string;
};

/** Open windows, from the compositor's own JSON. */
export async function windows(): Promise<HyprWindow[]> {
  const raw = await capture("hyprctl", ["clients", "-j"]);
  const parsed = JSON.parse(raw) as Array<{
    address: string;
    pid: number;
    class: string;
    title: string;
    workspace?: { name?: string };
  }>;
  return parsed
    .filter((client) => client.pid > 0)
    .map((client) => ({
      address: client.address,
      pid: client.pid,
      class: client.class || "(unknown)",
      title: client.title || "(untitled)",
      workspace: client.workspace?.name ?? "?",
    }));
}

/**
 * Ask a window to close, the way clicking its ✕ would.
 *
 * rofi-killwindow only ever did `kill -9`, which loses unsaved work and leaves
 * anything with a crash handler thinking it crashed. Closing through the
 * compositor gives the application its normal shutdown path; SIGKILL stays
 * available as a separate, explicitly destructive action for the windows that
 * ignore it.
 */
export async function closeWindow(address: string): Promise<void> {
  // Lua, not `dispatch closewindow address:0x…`: hyprctl hands a dispatch
  // argument to the same Lua parser the config uses since Hyprland 0.55, and
  // the classic form comes back as a syntax error having closed nothing —
  // which is what Mod+Escape had been doing to every window it was pointed at.
  await capture("hyprctl", ["dispatch", `hl.dsp.window.close({ window = "address:${address}" })`]);
}

export async function killWindow(pid: number): Promise<void> {
  process.kill(pid, "SIGKILL");
}

const HOME = process.env.HOME ?? "";

export type Monitor = {
  name: string;
  description: string;
  enabled: boolean;
  /** e.g. "2560x1440@144" — empty while disabled, since a disabled output reports no mode. */
  mode: string;
  /** False for the last enabled output, which the script refuses to disable. */
  canDisable: boolean;
};

/**
 * Outputs, from toggle-monitors.sh.
 *
 * Both halves go through the script, for the same reason the keyboard-layout
 * pair does. An earlier version read `hyprctl -j monitors all` here on the
 * grounds that listing is a plain read — but the script's `query_outputs` is
 * not a plain read: it sorts by name, derives the label from make+model,
 * inverts `disabled` and formats the mode, and all four were re-implemented
 * here. Worse, `canDisable` was recomputed in the UI as `activeCount <= 1`,
 * which made the copy the thing that decided whether the action was offered.
 */
export async function monitors(): Promise<Monitor[]> {
  const lines = await captureLines(`${HOME}/.local/bin/toggle-monitors.sh`, ["list"]);
  return lines.flatMap((line) => {
    const [name, enabled, mode, canDisable, label] = line.split("\t");
    if (!name) return [];
    return [{
      name,
      description: label || name,
      enabled: enabled === "1",
      mode: mode ?? "",
      canDisable: canDisable === "1",
    }];
  });
}

export async function toggleMonitor(name: string): Promise<void> {
  await capture(`${HOME}/.local/bin/toggle-monitors.sh`, ["toggle", name], { timeout: 30_000 });
}

export type KeyboardLayout = { name: string; isActive: boolean };

/**
 * Keyboard layouts, from toggle-keyboard-layout.sh.
 *
 * The script owns both halves for a reason: which layout is *active* is decided
 * from Hyprland's live kb_layout/kb_variant rather than from persisted state,
 * and that rule belongs next to the runtime eval that applies a layout.
 */
export async function keyboardLayouts(): Promise<KeyboardLayout[]> {
  const lines = await captureLines(`${HOME}/.config/hypr/scripts/toggle-keyboard-layout.sh`, ["list"]);
  return lines.flatMap((line) => {
    const [name, active] = line.split("\t");
    return name ? [{ name, isActive: active === "1" }] : [];
  });
}

export async function setKeyboardLayout(name: string): Promise<void> {
  await capture(`${HOME}/.config/hypr/scripts/toggle-keyboard-layout.sh`, ["set", name], { timeout: 30_000 });
}

export type DesktopApp = { id: string; name: string; icon: string };

/**
 * Installed apps declaring a freedesktop category, from desktop-apps.
 *
 * The crawl (NoDisplay filtering, dedupe on display name) is in the script so
 * that the pickers and the plain `Mod+B` default-browser path cannot disagree
 * about what is installed — and so that a new picker is a category string here
 * rather than a second copy of the scan.
 */
export async function desktopApps(category: string): Promise<DesktopApp[]> {
  const lines = await captureLines(`${HOME}/.local/bin/desktop-apps`, ["list", category]);
  return lines.flatMap((line) => {
    const [id, name, icon] = line.split("\t");
    return id ? [{ id, name: name || id, icon: icon || "" }] : [];
  });
}

export async function launchDesktopApp(id: string): Promise<void> {
  await capture(`${HOME}/.local/bin/desktop-apps`, ["launch", id], { timeout: 15_000 });
}

export type Browser = { id: string; name: string; icon: string; isDefault: boolean };

/**
 * Installed browsers, from browser-launch.sh.
 *
 * The scan is a freedesktop crawl for `Categories=*WebBrowser` with NoDisplay
 * filtering and a dedupe on display name — no hardcoded browser list, which is
 * what lets an AppImage that registers a desktop file show up. Kept in the
 * script so the plain `Mod+B` path and this command cannot disagree.
 */
export async function browsers(): Promise<Browser[]> {
  const lines = await captureLines(`${HOME}/.local/bin/browser-launch.sh`, ["list"]);
  return lines.flatMap((line) => {
    const [id, name, icon, isDefault] = line.split("\t");
    return id ? [{ id, name: name || id, icon: icon || "", isDefault: isDefault === "1" }] : [];
  });
}
