<!--
The real file behind ~/.claude/CLAUDE.md, which is a symlink to this one
(home/dot_claude/symlink_CLAUDE.md.tmpl creates it).

Deliberately NOT named CLAUDE.md: Claude Code discovers CLAUDE.md files in
subdirectories below the working directory and loads them on demand, so a
claude/CLAUDE.md here would be pulled into context a second time whenever
anything in this directory is read.

Symlink rather than a plain chezmoi-managed file so it can be edited in place
from any machine — the target IS this file, so an edit is a repo edit, and
`git push` / `dots update` is the whole sync. A managed copy would need
`chezmoi re-add` after every edit, which is the step nobody remembers.

Keep it under 200 lines: CLAUDE.md files load in full at every session, and
shorter files get followed more reliably. When this grows past two or three
topics, split it into ~/.claude/rules/*.md (same idea, one file per subject,
and that directory accepts symlinks too).

HTML comments like this one are stripped before the content reaches Claude's
context, so this block costs no tokens.
-->

## Language

- **Reply in the language of the message you are answering.** The user writes
  French and English and switches mid-thread, so this follows the message, not
  the thread — and never the language of the code in front of you.
- **Only the prose addressed to them switches.** Code, identifiers, commit
  messages, and every file written to disk stay in English, including in a
  conversation held entirely in French.

## Sudo

- **Print every sudo command before running it**, in a fenced `bash` block, exactly as it will run. The ksshaskpass dialog that asks for the password shows sudo's prompt and never the command, so printing it is the only way to see what is about to run as root. Sessions run with `--permission-mode bypassPermissions`, which means no permission prompt will ever show it either — this rule is the whole mechanism, not a courtesy on top of one.
- **One block per turn is enough.** List every sudo command the turn will run, then run them; do not interleave a block per call.
- **Say so when sudo is reached indirectly.** A script or a `dots` command that calls sudo internally never shows the word in what gets typed — name it anyway ("`dots update` will call sudo for the package upgrade"), because that is exactly the case nothing else can catch.

## Tools you maintain

- **Restarting `vibewatch` needs no permission** — `systemctl --user restart vibewatch.service` is idempotent: the daemon rebuilds its whole session list by rescanning processes and transcripts on boot, so a restart mid-fleet loses nothing. Never leave a change to it merely compiled — `cargo install --path .`, restart, then look at the result. (Its source is its own repo, which is why this is here rather than in the dotfiles.)

## File paths in answers

- **Always write file paths inside backticks** — `src/app.ts:42`, `packages/groups/`.
  I work in T3 Code, which only turns a path into a link inside an inline-code span
  or a markdown link destination (`apps/web/src/components/ChatMarkdown.tsx`), so a
  path written in bare prose is dead text however it is spelled. Once backticked,
  relative, absolute and `~/…` all resolve to the same file and the chip renders
  workspace-relative either way — relative is a readability preference, not what
  makes the link work. A `:42` or `:42:7` suffix rides along and opens on that line.
