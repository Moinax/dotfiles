import { worktreeBranchPaths } from "./git";
import { capture, captureLines, CommandError, spawnDetached } from "./shell";

/**
 * The two launches, both delegated to the same helpers the shell functions use.
 *
 * Nothing about *how* a checkout is opened lives here. `dev` owns the zellij
 * tab, its "<project>.<branch>" name and the terminal window, and
 * `wt-switch-args` owns deciding between a plain switch and a --create. This
 * module is the second caller of that same set, after the zsh `wtstart` — which
 * is the point: behaviour cannot drift between the launcher and the shell,
 * because there is only one copy of it.
 *
 * A main checkout and a worktree are the same call. They were two only while a
 * worktree meant an agent pane with a provider and an optional /start; the
 * agents live in T3 Code now, and what is left is a directory to open.
 */

/** Open a checkout as a tab in the zellij session, and focus the terminal. */
export async function openDevWorkspace(path: string): Promise<void> {
  await spawnDetached("dev", [path]);
}

export type WorktreeLaunch = {
  /** Main checkout of the repository the branch belongs to. */
  repo: string;
  branch: string;
  /** Called with a human-readable step, so the caller can drive a Toast. */
  onProgress?: (step: string) => void;
};

/**
 * Create or reopen a worktree for a branch and launch its dev workspace.
 *
 * The rofi version had to announce the slow part with notify-send, because a
 * rofi window is gone the moment Enter lands and a few seconds of silence read
 * as a swallowed keypress. Here the launcher stays up and `onProgress` drives a
 * real Toast, so the fetch and the worktree creation are visible where the user
 * is already looking.
 */
export async function launchWorktree(options: WorktreeLaunch): Promise<string> {
  const { repo, branch, onProgress } = options;

  // wt-switch-args prints "--create" only for a branch that is genuinely new,
  // and nothing for one that exists locally or on origin — the distinction that
  // routes a colleague's branch to a tracking checkout instead of forking an
  // empty branch off main and dropping their work. It fetches origin first when
  // the branch is unknown, which is the slow step worth announcing.
  onProgress?.(`Resolving ${branch}…`);
  const switchArgs = await captureLines("wt-switch-args", [branch], { cwd: repo, timeout: 60_000 });

  onProgress?.(switchArgs.includes("--create") ? `Creating worktree for ${branch}…` : `Opening ${branch}…`);
  try {
    // --no-cd: there is no shell here for `wt` to cd, unlike the wtstart
    // functions it shares wt-switch-args with.
    await capture("wt", ["switch", ...switchArgs, branch, "--no-cd"], { cwd: repo, timeout: 180_000 });
  } catch (error) {
    // wt asks for a one-time per-repo approval of the hooks in .config/wt.toml
    // and there is no terminal here to answer in. Point at the fix rather than
    // relaying "cannot prompt in non-interactive environment".
    if (error instanceof CommandError && /approval/i.test(error.message)) {
      throw new Error(`${repo} has unapproved hooks. Run: wt config approvals add -C ${repo}`);
    }
    throw error;
  }

  // The porcelain parser lives in git.ts, which already had one for the branch
  // buckets. A second copy here meant three parsers of the same format in the
  // extension, each restating the record rules.
  const worktreePath = (await worktreeBranchPaths(repo)).byBranch.get(branch);
  if (!worktreePath) throw new Error(`Could not locate the worktree for ${branch}`);

  onProgress?.(`Launching ${branch}…`);
  await openDevWorkspace(worktreePath);

  return worktreePath;
}

