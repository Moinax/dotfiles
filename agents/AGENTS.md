# Global agent instructions

<!--
Shared by the global Codex and Claude entry points through chezmoi-managed
symlinks. Edit this source; changes also update the local entry points.
Keep tool-specific rules in that tool's own configuration.
-->

## Language

- **Reply in the language of the message you are answering.** The user writes
  French and English and switches mid-thread. Follow the current message,
  regardless of the language of the code.
- **Only the prose addressed to them switches.** Code, identifiers, commit
  messages, and every file written to disk stay in English, including in a
  conversation held entirely in French.

## Human-facing prose

- **Always apply `unslop` to English or French prose written for people.**
  Apply it silently — never announce the skill or narrate the decision.

## Test windows on Hyprland

- **All GUI apps and browsers launched for testing or verification MUST open on
  workspace 5 without taking focus.** The user must be able to keep working while
  tests run. This applies to test runners, previews, dialogs, and child windows.
- **Arrange silent placement before launching.** Use the installed Hyprland
  version's supported launch options or another verified mechanism. Never open
  on the current workspace and move the window afterward. Verify placement and
  that the user's focused window and workspace remain unchanged.
- **Never switch to workspace 5, activate test windows, or send desktop-wide
  keyboard or mouse input unless the user explicitly asks.** Use automation
  scoped to the test app. Close only windows or processes created for your tests.
- **Use a separate browser instance and test profile.** Never reuse the user's
  browser session. Prefer headless tests or background previews when sufficient.
- **If silent GUI testing is unavailable, use a headless or isolated alternative.**
  If the task requires visible interaction and no such alternative works, explain
  the limitation before launching. Do not fall back to interrupting the desktop.

## Sudo

- **Print every sudo command before running it**, in a fenced `bash` block, exactly as it will run. The ksshaskpass password dialog shows sudo's prompt, not the command. Print the command so the user can see what will run as root, even when tool approvals are disabled.
- **One block per turn is enough.** List every sudo command the turn will run, then run them; do not interleave a block per call.
- **Say so when sudo is reached indirectly.** A script or a `dots` command that calls sudo internally never shows the word in what gets typed — name it anyway ("`dots update` will call sudo for the package upgrade"), because that is exactly the case nothing else can catch.

## Tools you maintain

- **Restarting `vibewatch` needs no permission** — `systemctl --user restart vibewatch.service` is idempotent: the daemon rebuilds its whole session list by rescanning processes and transcripts on boot, so a restart mid-fleet loses nothing. Never leave a change to it merely compiled — `cargo install --path .`, restart, then look at the result. (Its source is its own repo, which is why this is here rather than in the dotfiles.)

## File paths in answers

- **Always use absolute file paths, inside backticks or as Markdown link destinations**
  — `/home/me/project/src/app.ts:42`, not `src/app.ts:42`. T3 Code turns either
  form into a workspace-relative chip, but a relative path depends on the thread's
  cwd while an absolute one resolves on its own. A `:42` or `:42:7` suffix opens
  the file at that position.

## Scratch files

- **Write throwaway artifacts under `.scratch/` at the workspace root, never `/tmp`.**
  Mockups, prototypes, one-off scripts, generated reports. T3 Code's integrated
  browser only serves files below the workspace root, so an HTML file in `/tmp` gets
  a clickable chip that cannot open it — the click silently falls back to the editor
  and the preview never renders. `.scratch/` sits in my global gitignore
  (`~/.config/git/ignore`), so it stays out of `git status` and out of hunk.
