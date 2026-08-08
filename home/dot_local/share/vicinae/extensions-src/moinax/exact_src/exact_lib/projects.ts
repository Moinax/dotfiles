import { basename } from "node:path";
import { capture, captureLines } from "./shell";

/**
 * The project tree, read through `dev-projects` — never re-derived here.
 *
 * `dev-projects` is the single source of truth CLAUDE.md points at: the root
 * directory, the two-levels-deep listing convention, the pinned out-of-root
 * entries (~/dotfiles), and the directory → herdr session mapping all live
 * there and are shared with dev-pick and dev-herdr. This module only shapes
 * what it prints into something a List can render.
 */

export type Project = {
  /** The entry as dev-projects prints it, e.g. "labs/pack/". The id everything else keys on. */
  entry: string;
  /** Absolute path, from `dev-projects list --paths`. */
  path: string;
  /** Last path segment, e.g. "pack" — what the user actually reads. */
  name: string;
  /** The parent group, e.g. "labs" — empty for a pinned entry sitting at the root. */
  group: string;
};

/**
 * Projects that are real git repositories, main checkouts only.
 *
 * `--paths` gets every absolute path in the same invocation, instead of one
 * `dev-projects resolve` process per row — the one thing rofi-dev could not do.
 *
 * Filtering out the intermediate directories the tree scan turns up (`labs/`,
 * `mbrella/`, the group folders) used to happen here, with a stat per row. It
 * belongs to `--main-only`, which now tests for a .git *directory* rather than
 * excluding worktrees by their .git file — so dev-pick and rofi-dev stopped
 * listing directories that fail at the point of selection too.
 */
export async function listProjects(): Promise<Project[]> {
  const rows = await captureLines("dev-projects", ["list", "--main-only", "--paths"]);

  // A dev-projects that predates --paths ignores the flag instead of rejecting
  // it, and prints bare entries with no tab. Every row then parses to nothing
  // and the command comes up as an empty project list — a blank screen with no
  // hint that the helper is simply out of date. Say so instead.
  if (rows.length > 0 && !rows.some((row) => row.includes("\t"))) {
    throw new Error("dev-projects is too old: `list --paths` printed no paths. Run `chezmoi apply ~/.local/bin/dev-projects`.");
  }

  return rows.flatMap((row) => {
    const tab = row.indexOf("\t");
    if (tab < 0) return [];
    const entry = row.slice(0, tab);
    const path = row.slice(tab + 1).replace(/\/+$/, "");
    if (!entry || !path) return [];
    const trimmedEntry = entry.replace(/\/+$/, "");
    const segments = trimmedEntry.split("/");
    return [{
      entry,
      path,
      name: segments[segments.length - 1] || basename(path),
      group: segments.slice(0, -1).join("/"),
    }];
  });
}

/**
 * The herdr session a directory belongs to.
 *
 * Deliberately a subprocess rather than "first path component under the root":
 * that rule has exceptions (pinned entries carry their own session, names get
 * legalised for herdr) and dev-projects owns it. Reimplementing it here is
 * exactly how two callers end up filing one directory under two sessions.
 * Only ever called for the selected row, so the process cost is paid once.
 */
export async function sessionFor(path: string): Promise<string> {
  return (await capture("dev-projects", ["session", path])).trim();
}
