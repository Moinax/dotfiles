import { ProjectList } from "./lib/project-list";

/**
 * Mod+Alt+Return — the vicinae replacement for rofi-dev, and the only entry
 * point into the project picker. The T3 Code picker on Mod+Ctrl+Return is its
 * counterpart; the two are the same three keystrokes, one per runner.
 *
 * There was briefly a second command (Dev Worktree) that rendered this exact
 * list with the two actions swapped, so that Enter landed on the worktrees
 * instead of on the main checkout. That is a thing an ActionPanel already does,
 * so the second command bought a keybind and a manifest entry to move one
 * action up one row. Dropped.
 *
 * Enter opens the project's dev workspace; Shift+Enter pushes its worktrees —
 * the same split the rofi version expressed with `-kb-custom-1` and an exit
 * code of 10. Shift rather than Ctrl because that is vicinae's default for a
 * panel's second action and neither declares a `shortcut`; the branch list's
 * Ctrl+Enter is declared, which is why it differs.
 */
export default function Command() {
  return <ProjectList />;
}
