---
name: simplify
description: Review and improve recently changed code for clarity, reuse, consistency, and efficiency without changing its intended behavior. Use when the user asks to simplify, clean up, refactor, polish, or reduce complexity in a working tree, diff, patch, or specified set of files.
---

# Simplify

Improve the current changes in place. Preserve intended behavior and public
interfaces unless the user explicitly authorizes a broader refactor.

## Workflow

1. Read the applicable repository instructions and inspect the working tree.
2. Establish the review scope from the user's request. Otherwise, use the
   current diff, including relevant untracked files. Do not modify unrelated
   user changes.
3. Read enough surrounding code to understand local conventions and existing
   abstractions before editing.
4. Look for:
   - unnecessary complexity, nesting, indirection, or special cases;
   - duplicated logic that can reuse an existing abstraction;
   - premature or single-use abstractions that obscure straightforward code;
   - redundant state, branches, allocations, conversions, or repeated work;
   - unclear names, control flow, or comments;
   - code made obsolete by the current changes;
   - inconsistent patterns within the affected area.
5. Apply only improvements with a clear readability, maintainability, or
   efficiency benefit. Prefer small, cohesive edits over speculative redesign.
6. Review the resulting diff for accidental behavior changes and scope creep.
7. Run the most relevant available formatting, linting, type-checking, and
   tests in proportion to the changes.
8. Report what was simplified, what validation ran, and any remaining concern.

## Constraints

- Preserve behavior, compatibility, error semantics, and observable ordering.
- Do not weaken validation, error handling, security checks, or tests merely to
  make the code shorter.
- Do not optimize for line count. Explicit code is preferable when it is easier
  to understand.
- Do not introduce a new helper or abstraction unless it removes meaningful
  duplication or clarifies a stable concept.
- Follow existing project conventions rather than imposing a new style.
- Keep unrelated edits intact and do not discard user work.
- If there are no identifiable changes and no explicit target, ask the user
  what should be simplified.
