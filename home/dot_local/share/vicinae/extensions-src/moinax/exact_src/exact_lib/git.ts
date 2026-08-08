import { capture, captureLines } from "./shell";

/**
 * Branch enumeration for the worktree picker.
 *
 * Same three buckets rofi-wts builds — branches that already have a worktree,
 * local branches that do not, and branches that exist only on origin — and for
 * the same reason: a colleague's branch is exactly as openable as a local one
 * (`wt switch` without --create checks it out tracking origin/<branch>), so
 * leaving it out is what forced typing the name blind.
 *
 * What is new is that every branch also carries its last commit. rofi could
 * only ever show the name, so "which of these six branches was I on last
 * week" had no answer inside the picker.
 */

export type BranchKind = "worktree" | "local" | "remote";

export type Branch = {
  name: string;
  kind: BranchKind;
  /** Checkout path — set only for a branch that already has a linked worktree. */
  worktreePath?: string;
  /** `git for-each-ref` relative committerdate, e.g. "3 days ago". */
  lastCommit: string;
  /** Subject line of the branch tip. */
  subject: string;
};

/**
 * Field separator for the for-each-ref formats below: ASCII unit separator.
 * Written as an escape, not as a literal control byte — a raw 0x1f in source is
 * invisible in every diff and every editor, and silently becomes something else
 * the first time the file is round-tripped. git forbids it in a ref name, so it
 * cannot turn up inside a field and split one row into two.
 */
const SEP = "\x1f";

export async function listBranches(repo: string): Promise<Branch[]> {
  const [worktreePaths, locals, remotes] = await Promise.all([
    worktreeBranchPaths(repo),
    refs(repo, "refs/heads", "%(refname:short)"),
    // lstrip=3 drops refs/remotes/origin/ properly. %(refname:short) cannot be
    // trusted here: it shortens refs/remotes/origin/HEAD to a bare "origin",
    // which rofi-wts once listed as a branch nothing could ever check out.
    refs(repo, "refs/remotes/origin", "%(refname:lstrip=3)"),
  ]);

  const localNames = new Set(locals.map((ref) => ref.name));
  const mainBranch = worktreePaths.mainBranch;

  const branches: Branch[] = [];
  for (const ref of locals) {
    const worktreePath = worktreePaths.byBranch.get(ref.name);
    // The main checkout is not a worktree row: `dev` already opens it.
    if (ref.name === mainBranch) continue;
    branches.push({ ...ref, kind: worktreePath ? "worktree" : "local", worktreePath });
  }
  for (const ref of remotes) {
    if (ref.name === "HEAD" || localNames.has(ref.name)) continue;
    branches.push({ ...ref, kind: "remote" });
  }

  return branches;
}

type Ref = { name: string; lastCommit: string; subject: string };

async function refs(repo: string, namespace: string, nameFormat: string): Promise<Ref[]> {
  const lines = await captureLines(
    "git",
    [
      "for-each-ref",
      namespace,
      "--sort=-committerdate",
      `--format=${nameFormat}${SEP}%(committerdate:relative)${SEP}%(subject)`,
    ],
    { cwd: repo },
  );
  return lines.flatMap((line) => {
    const [name, lastCommit = "", subject = ""] = line.split(SEP);
    return name ? [{ name, lastCommit, subject }] : [];
  });
}

/**
 * Branch → linked worktree path, plus the branch of the main checkout.
 *
 * `git worktree list --porcelain` emits a blank-line-separated record per
 * worktree, each starting with `worktree <path>` and (unless detached) carrying
 * a `branch refs/heads/<name>`. The first record is always the main checkout.
 */
export async function worktreeBranchPaths(repo: string): Promise<{ byBranch: Map<string, string>; mainBranch: string | null }> {
  const stdout = await capture("git", ["worktree", "list", "--porcelain"], { cwd: repo });
  const byBranch = new Map<string, string>();
  let mainBranch: string | null = null;
  let path: string | null = null;
  let isFirst = true;

  for (const line of stdout.split("\n")) {
    if (line.startsWith("worktree ")) {
      path = line.slice("worktree ".length);
    } else if (line.startsWith("branch refs/heads/")) {
      const name = line.slice("branch refs/heads/".length);
      if (isFirst) {
        mainBranch = name;
      } else if (path) {
        byBranch.set(name, path);
      }
    } else if (line === "") {
      if (path) isFirst = false;
      path = null;
    }
  }
  return { byBranch, mainBranch };
}

export type RepoStatus = {
  branch: string;
  /** Number of modified/untracked entries — 0 means clean. */
  dirtyCount: number;
  lastCommit: string;
  worktreeCount: number;
};

/**
 * Status of a repository, for the detail panel of the selected project.
 *
 * Only ever run for one project at a time (on selection change), never across
 * the whole list: `git status` on thirty repositories at once is the kind of
 * per-row cost CLAUDE.md warns about measuring before calling cheap.
 */
export async function repoStatus(repo: string): Promise<RepoStatus> {
  // `status --porcelain -b` prefixes a `## <branch>...` header, so the branch
  // comes free with the dirty count — a separate `git branch --show-current`
  // was a fourth process spawned per project selection for a fact already in
  // hand.
  const [porcelain, lastCommit, worktrees] = await Promise.all([
    capture("git", ["status", "--porcelain", "-b"], { cwd: repo }),
    capture("git", ["log", "-1", "--format=%s (%cr)"], { cwd: repo }),
    capture("git", ["worktree", "list", "--porcelain"], { cwd: repo }),
  ]);

  const lines = porcelain.split("\n");
  // `## main...origin/main [ahead 1]` on a branch, `## HEAD (no branch)` detached.
  const header = lines.find((line) => line.startsWith("## ")) ?? "";
  const branch = header.slice(3).split("...")[0].trim();

  return {
    branch: !branch || branch.startsWith("HEAD (no branch)") ? "(detached)" : branch,
    dirtyCount: lines.filter((line) => line.trim().length > 0 && !line.startsWith("## ")).length,
    lastCommit: lastCommit.trim(),
    // Minus the main checkout, which `worktree list` always reports first.
    worktreeCount: Math.max(0, worktrees.split("\n").filter((line) => line.startsWith("worktree ")).length - 1),
  };
}
