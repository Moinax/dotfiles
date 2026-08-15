import { T3ProjectList } from "./lib/t3-project-list";

/**
 * Mod+Alt+Return — the T3 Code counterpart to Mod+Ctrl+Return's herdr picker.
 *
 * Same three keystrokes for the same intent, against the other runner: pick a
 * project, land in its work. Enter on a project opens its threads (registering
 * the project first if T3 Code has never seen it), and Enter there either opens
 * an existing thread or creates one named after whatever was typed.
 *
 * No worktree step, unlike the herdr picker's Shift+Enter. T3 Code's worktrees
 * are created from inside the app against a branch it then owns for the life of
 * the thread, so offering one here would be a second way to make something the
 * app already makes better — and the thing this picker is for is getting to a
 * conversation, not to a checkout.
 */
export default function Command() {
  return <T3ProjectList />;
}
