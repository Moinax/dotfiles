import { capture } from "./shell";

/**
 * T3 Code's projects and threads, read through `t3-thread` — never re-derived.
 *
 * Same split as `projects.ts` and `dev-projects`: the helper owns where the
 * state lives (a read-only sqlite handle), how a thread is created (a signed
 * POST to the orchestration API) and how one is focused (the deep-link socket,
 * then the compositor). This module only shapes what it prints. That matters
 * more here than usual, because the extension is build output — a rule kept
 * only in a .tsx is a rule no keybind or status bar can reuse.
 */

export type T3Project = {
  project_id: string;
  title: string;
  workspace_root: string;
};

/** A thread as the picker needs it: enough to sort, mark and open. */
export type T3Thread = {
  thread_id: string;
  title: string;
  project_id: string;
  /** Provider session state — "idle" when the thread has never run. */
  status: string;
  updated_at: string;
  /** Approvals waiting on an answer. Non-zero means the agent is blocked. */
  pending: number;
};

async function rows<T>(args: string[]): Promise<T[]> {
  const stdout = (await capture("t3-thread", args)).trim();
  // sqlite3 prints nothing at all for an empty result set, which JSON.parse
  // reports as an unexpected end of input — a confusing way to say "no rows".
  return stdout ? (JSON.parse(stdout) as T[]) : [];
}

export function listT3Projects(): Promise<T3Project[]> {
  return rows<T3Project>(["projects"]);
}

/** Live threads, newest first. Every project at once when `projectId` is omitted. */
export function listT3Threads(projectId?: string): Promise<T3Thread[]> {
  return rows<T3Thread>(projectId ? ["threads", projectId] : ["threads"]);
}

/**
 * Is an agent actually working in this thread?
 *
 * Lives here rather than in a view because it is the same kind of knowledge as
 * the field comments above — what the status *means* — and every view needs it.
 * Left in two components it drifted immediately: the project list counted
 * `running|starting` while the thread list painted `ready` green too, so one
 * `ready` thread showed a green dot and "0 running" at the same time.
 *
 * `stopped`, `interrupted` and `error` are all "not working" here. Only `error`
 * is worth a different colour, and that is a view's call, not this one's.
 */
export function isThreadLive(thread: Pick<T3Thread, "status">): boolean {
  return thread.status === "running" || thread.status === "starting" || thread.status === "ready";
}

/** Register a workspace root as a T3 Code project; resolves to its id. */
export async function addT3Project(path: string, title: string): Promise<string> {
  return (await capture("t3-thread", ["project-add", path, title], { timeout: 60_000 })).trim();
}

/**
 * Create a thread and resolve to its id.
 *
 * The model, effort and context size are the project's own defaults, decided by
 * `t3-thread` rather than passed from here: they are a T3 Code setting, and a
 * picker that carried its own copy would quietly diverge from what the app does
 * on `New thread`.
 */
export async function newT3Thread(projectId: string, title: string): Promise<string> {
  return (await capture("t3-thread", ["new", projectId, title], { timeout: 30_000 })).trim();
}

/**
 * Open a thread in T3 Code and raise the window.
 *
 * The generous timeout is the cold-start path, where the helper starts the app
 * and waits for its window before handing over the link. The raise that follows
 * is detached and outlives this call by design — it has to land after the
 * launcher closes — so nothing here waits on focus.
 */
export async function focusT3Thread(threadId: string): Promise<void> {
  await capture("t3-thread", ["focus", threadId], { timeout: 45_000 });
}
