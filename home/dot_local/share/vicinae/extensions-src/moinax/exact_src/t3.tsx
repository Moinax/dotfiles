import { T3ProjectList } from "./lib/t3-project-list";

/**
 * Mod+Ctrl+Return — the T3 Code counterpart to Mod+Alt+Return's project picker.
 *
 * Same three keystrokes for the same intent, against the other runner: pick a
 * project, land in its work. Enter on a project opens its thread list. Enter
 * there opens an existing thread or a native draft for the first prompt.
 *
 * No worktree step, unlike the project picker's Shift+Enter. T3 Code's worktrees
 * are created from inside the app against a branch it then owns for the life of
 * the thread, so offering one here would be a second way to make something the
 * app already makes better — and the thing this picker is for is getting to a
 * conversation, not to a checkout.
 */
export default function Command() {
  return <T3ProjectList />;
}
