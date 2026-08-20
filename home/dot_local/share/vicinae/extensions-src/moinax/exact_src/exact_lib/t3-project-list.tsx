import { Action, ActionPanel, Color, Icon, List, showToast, Toast, useNavigation } from "@vicinae/api";
import { useMemo } from "react";
import { listProjects, type Project } from "./projects";
import {
  addT3Project,
  isThreadLive,
  listT3Projects,
  listT3Threads,
  type T3Project,
  type T3Thread,
} from "./t3";
import { ThreadList } from "./thread-list";
import { describeError, useLoader } from "./ui";

/** A project row: the directory, plus what T3 Code already knows about it. */
type Row = {
  project: Project;
  /** null until T3 Code has been told about this directory. */
  projectId: string | null;
  threads: number;
  /** Threads with an agent actually working. */
  live: number;
  /** Threads blocked on an approval or a question. */
  waiting: number;
};

type Counts = { threads: number; live: number; waiting: number };
const NO_THREADS: Counts = { threads: 0, live: 0, waiting: 0 };

/**
 * Projects, from both sides at once.
 *
 * The directory list is `dev-projects` — the same source the dev picker uses,
 * so the two pickers never disagree about what a project is. What T3 Code knows
 * is layered on top: registered or not, and how much is running. A project it
 * has never seen is not hidden, because adding one is exactly what this picker
 * is for; it just sorts below the ones already in play.
 *
 * Threads are fetched once for every project rather than per row. The per-row
 * shape is what the dev picker deliberately avoids for git status, and here it
 * would be worse: one subprocess per project on open, for a number that is one
 * column of one query.
 */
async function loadRows(): Promise<Row[]> {
  const [projects, [t3Projects, threads]] = await Promise.all([
    listProjects(),
    // What T3 Code knows is an annotation on this list, never a condition of
    // it. Listed flat in the same `Promise.all`, it was one: any failure
    // reading the projection — the app down, a renamed column, the helper not
    // on PATH — rejected the whole load, and the picker said "No projects
    // found" over a disk full of repositories. The one row that then mattered,
    // "Add to T3 Code…", was the one that had disappeared with it.
    //
    // One catch over both reads rather than one each: they are the same helper
    // against the same file, so they fail together, and a catch apiece said the
    // same thing twice. The toast is not awaited — the list is ready, and
    // nothing about it depends on the notification having been drawn.
    Promise.all([listT3Projects(), listT3Threads()]).catch((error) => {
      void showToast({
        style: Toast.Style.Failure,
        title: "T3 Code state unavailable",
        message: describeError(error),
      });
      return [[], []] as [T3Project[], T3Thread[]];
    }),
  ]);

  const byPath = new Map(t3Projects.map((project) => [project.workspace_root, project]));
  const counts = new Map<string, Counts>();
  for (const thread of threads) {
    const row = counts.get(thread.project_id) ?? { ...NO_THREADS };
    row.threads += 1;
    if (isThreadLive(thread)) row.live += 1;
    if (thread.pending > 0) row.waiting += 1;
    counts.set(thread.project_id, row);
  }

  const row = (project: Project, projectId: string | null): Row => ({
    project,
    projectId,
    ...((projectId ? counts.get(projectId) : undefined) ?? NO_THREADS),
  });

  const rows = projects.map((project) => row(project, byPath.get(project.path)?.project_id ?? null));

  // A T3 Code project outside the projects root — added by hand, or living
  // somewhere dev-projects does not scan — would otherwise be invisible here
  // while being perfectly openable. Synthesised from its workspace root, which
  // is the only thing the projection stores about where it is.
  const known = new Set(projects.map((project) => project.path));
  for (const t3 of t3Projects) {
    if (known.has(t3.workspace_root)) continue;
    const path = t3.workspace_root;
    rows.push(row({ entry: path, path, name: t3.title, group: "" }, t3.project_id));
  }

  return rows;
}

export function T3ProjectList() {
  const { rows, isLoading } = useLoader<Row>(loadRows, "Could not list projects");

  // Sections, not a sort key: "already in T3 Code" and "everything else on
  // disk" are two different questions, and a single ordered list makes the
  // boundary between them something the user has to infer from the tags.
  const sections = useMemo(
    () =>
      [
        { title: "In T3 Code", rows: rows.filter((row) => row.projectId !== null) },
        { title: "Other projects", rows: rows.filter((row) => row.projectId === null) },
      ].filter((section) => section.rows.length > 0),
    [rows],
  );

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search projects" navigationTitle="T3 Code">
      <List.EmptyView
        icon={Icon.Folder}
        title="No projects found"
        description="dev-projects found no git repositories, and T3 Code has none registered."
      />
      {sections.map((section) => (
        <List.Section key={section.title} title={section.title}>
          {section.rows.map((row) => (
            <List.Item
              key={row.project.path}
              title={row.project.name}
              subtitle={row.project.group}
              icon={{ source: Icon.Code, tintColor: row.projectId ? Color.Blue : Color.SecondaryText }}
              keywords={[row.project.entry, row.project.path]}
              accessories={accessories(row)}
              actions={<RowActions row={row} />}
            />
          ))}
        </List.Section>
      ))}
    </List>
  );
}

/**
 * Enter opens the project's threads. For a directory T3 Code has never seen,
 * that means registering it first — in the action, so the view it pushes always
 * holds a real project id and never has to model its absence.
 *
 * This is not the implicit-`/start` the worktree picker refuses: the row says
 * "Add to T3 Code…", so it was asked for, and registering a workspace root is
 * inert metadata rather than an agent run.
 */
function RowActions({ row }: { row: Row }) {
  const { push } = useNavigation();
  const open = (projectId: string) => push(<ThreadList project={row.project} projectId={projectId} />);

  return (
    <ActionPanel>
      {row.projectId === null ? (
        <Action
          title="Add to T3 Code…"
          icon={Icon.Plus}
          onAction={async () => {
            try {
              open(await addT3Project(row.project.path, row.project.name));
            } catch (error) {
              // The launcher stays open on failure, so the toast lands next to
              // the row that was pressed rather than over a view that opened
              // anyway on a project that does not exist.
              await showToast({
                style: Toast.Style.Failure,
                title: "Could not add the project",
                message: describeError(error),
              });
            }
          }}
        />
      ) : (
        <Action.Push
          title="Open Threads…"
          icon={Icon.SpeechBubble}
          target={<ThreadList project={row.project} projectId={row.projectId} />}
        />
      )}
      <Action.CopyToClipboard
        title="Copy Path"
        content={row.project.path}
        shortcut={{ modifiers: ["ctrl"], key: "c" }}
      />
    </ActionPanel>
  );
}

/** Blocked first, then running, then the plain total — loudest state wins the eye. */
function accessories(row: Row) {
  if (row.projectId === null) return [];
  const tags = [];
  if (row.waiting > 0) tags.push({ tag: { value: `${row.waiting} waiting`, color: Color.Orange } });
  if (row.live > 0) tags.push({ tag: { value: `${row.live} running`, color: Color.Green } });
  tags.push({ text: `${row.threads}` });
  return tags;
}
