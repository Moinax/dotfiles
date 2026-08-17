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

## Sudo

- **Print every sudo command before running it**, in a fenced `bash` block, exactly as it will run. The ksshaskpass dialog that asks for the password shows sudo's prompt and never the command, so printing it is the only way to see what is about to run as root. Sessions run with `--permission-mode bypassPermissions`, which means no permission prompt will ever show it either — this rule is the whole mechanism, not a courtesy on top of one.
- **One block per turn is enough.** List every sudo command the turn will run, then run them; do not interleave a block per call.
- **Say so when sudo is reached indirectly.** A script or a `dots` command that calls sudo internally never shows the word in what gets typed — name it anyway ("`dots update` will call sudo for the package upgrade"), because that is exactly the case nothing else can catch.

## Git

- **Never `git add`, `git commit` or `git push`** unless the user or a user-invoked skill asks for it. Finish the work, leave it **unstaged** in the working tree, and say it is ready — hunk (the user's reviewer) watches unstaged changes, so staging a file removes it from review. This applies to `git add` on its own: staging is not a harmless intermediate step, and not a nicer way to present a rename.
- **Each authorization covers only the change in front of you.** "Commit this" is not standing consent for the rest of the session, for follow-up edits, or for a fix made seconds later; ask again. "Commit" never implies push, and "push" of one commit never implies pushing later ones.
- **Never create a branch or a worktree** unless the user or a user-invoked skill asked for it. Work on the current branch, even when the change feels branch-worthy — say so and let the user decide.
