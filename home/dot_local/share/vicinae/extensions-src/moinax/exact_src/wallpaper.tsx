import { Action, ActionPanel, getPreferenceValues, Grid, Icon, showToast, Toast } from "@vicinae/api";
import { basename } from "node:path";
import { homedir } from "node:os";
import { useCallback } from "react";
import { capture, captureLines } from "./lib/shell";
import { describeError, useLoader } from "./lib/ui";

/**
 * Mod+Shift+W — the replacement for wallpaper-picker.sh's rofi half.
 *
 * rofi could only render a wallpaper as a one-line row with a small square
 * icon, which is why that picker needed its own theme file just to make the
 * icons big enough to tell two photographs apart. A Grid shows the actual
 * images at actual size, which is the only thing a wallpaper picker is for.
 *
 * Neither half is reimplemented here. `wallpaper-picker.sh apply` owns the awww
 * daemon handling, including the "never restart a live daemon or it flashes the
 * previous wallpaper" rule that is easy to lose in a rewrite; `list` owns what
 * counts as a wallpaper. Enumerating here instead meant the extension list and
 * the directory default could drift from the script's, and the `wallpaperDir`
 * preference below pointed at a directory the script could not see — so the two
 * front doors of one picker could offer different images.
 */

const PICKER = `${homedir()}/.local/bin/wallpaper-picker.sh`;

export default function Command() {
  const { wallpaperDir } = getPreferenceValues<{ wallpaperDir?: string }>();
  const dir = wallpaperDir || process.env.WALLPAPER_DIR || "";

  const load = useCallback(() => captureLines(PICKER, dir ? ["list", dir] : ["list"]), [dir]);
  const { rows: files, isLoading } = useLoader<string>(load, "Could not list wallpapers");

  return (
    <Grid
      isLoading={isLoading}
      columns={4}
      // Wallpapers are landscape and should be cropped to a common shape rather
      // than letterboxed — a grid of differently-proportioned thumbnails is
      // harder to scan than the rofi list it replaces.
      aspectRatio="16/9"
      fit={Grid.Fit.Fill}
      inset={Grid.Inset.Small}
      searchBarPlaceholder="Search wallpapers"
      navigationTitle="Wallpaper"
    >
      <Grid.EmptyView
        icon={Icon.Image}
        title="No wallpapers"
        description={`No images found in ${dir || "~/Wallpapers"}.`}
      />
      {/* `list` prints absolute paths, so the row keys on the path and the
          display name is derived from it rather than the other way round. */}
      {files.map((path) => {
        const name = basename(path);
        return (
          <Grid.Item
            key={path}
            id={path}
            content={{ source: path }}
            title={name.replace(/\.[^.]+$/, "")}
            actions={
              <ActionPanel>
                <Action
                  title="Set Wallpaper"
                  icon={Icon.Image}
                  onAction={async () => {
                    const toast = await showToast({ style: Toast.Style.Animated, title: `Applying ${name}…` });
                    try {
                      // Generous timeout: a cold awww-daemon start waits up to
                      // five seconds for the socket before the transition runs.
                      await capture(PICKER, ["apply", path], { timeout: 30_000 });
                      toast.style = Toast.Style.Success;
                      toast.title = name;
                      await toast.update();
                    } catch (error) {
                      toast.style = Toast.Style.Failure;
                      toast.title = "Could not set wallpaper";
                      toast.message = describeError(error);
                      await toast.update();
                    }
                  }}
                />
                <Action.CopyToClipboard title="Copy Path" content={path} shortcut={{ modifiers: ["ctrl"], key: "c" }} />
                <Action.ShowInFinder title="Reveal in File Manager" path={path} />
              </ActionPanel>
            }
          />
        );
      })}
    </Grid>
  );
}
