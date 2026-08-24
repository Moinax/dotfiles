## File paths in answers

- **Always use absolute file paths, inside backticks or as Markdown link destinations**
  — `/home/me/project/src/app.ts:42`, not `src/app.ts:42`. T3 Code turns either
  form into a workspace-relative chip, but a relative path depends on the thread's
  cwd while an absolute one resolves on its own. A `:42` or `:42:7` suffix opens
  the file at that position.
