import { Action, ActionPanel, Color, Icon, List } from "@vicinae/api";
import { useCallback, useMemo, useState } from "react";
import { listBranches, type Branch, type BranchKind } from "./git";
import { launchWorktree, openDevWorkspace } from "./launch";
import type { Project } from "./projects";
import { closeAfter, closeAfterProgress, useLoader } from "./ui";

const KIND: Record<BranchKind, { section: string; icon: Icon; color: Color; tag: string }> = {
  // One icon family, three states, the way the rofi rows used folder /
  // folder-open / folder-remote — except these are real icons rather than
  // nerd-font glyphs pasted into the row text, which degrade to spaces on the
  // way into a file and forced rofi-wts to smuggle them through the dmenu
  // `\0icon\x1f` protocol instead.
  worktree: { section: "Worktrees", icon: Icon.Folder, color: Color.Green, tag: "worktree" },
  local: { section: "Local branches", icon: Icon.Git, color: Color.Blue, tag: "local" },
  remote: { section: "Remote branches", icon: Icon.Cloud, color: Color.Purple, tag: "origin" },
};

const ORDER: BranchKind[] = ["worktree", "local", "remote"];

export function BranchList({ project }: { project: Project }) {
  const load = useCallback(() => listBranches(project.path), [project.path]);
  const { rows: branches, isLoading } = useLoader<Branch>(load, "Could not list branches");
  const [query, setQuery] = useState("");

  // The sections depend only on `branches`, never on the search text — the list
  // is uncontrolled, so the host does the filtering and every row stays mounted
  // regardless of what is typed. Without this memo each keystroke rebuilt every
  // row and its ActionPanel: t3code has 270 refs, so a 12-character branch name
  // meant ~3200 discarded List.Items and twice as many closures.
  const sections = useMemo(
    () =>
      ORDER.map((kind) => ({ kind, rows: branches.filter((branch) => branch.kind === kind) })).filter(
        (section) => section.rows.length > 0,
      ),
    [branches],
  );

  const typed = query.trim();
  // Only offer to create what does not already exist. `branches` covers local,
  // worktree and origin-only names, so a colleague's branch is matched here and
  // routed to a tracking checkout rather than offered as a new one.
  const canCreate = typed.length > 0 && !branches.some((branch) => branch.name === typed);

  return (
    <List
      isLoading={isLoading}
      // `filtering` has to be asked for explicitly here. It defaults to true,
      // but only until an `onSearchTextChange` handler appears — the API reads
      // that as "this extension filters by itself" and hands the whole list
      // through unfiltered. Leaving the search text uncontrolled is not enough
      // (that was the earlier belief, and it showed every branch in the
      // repository no matter what was typed); the handler alone flips it. The
      // text is mirrored out only so the "New branch" row below can name it,
      // so the built-in fuzzy match is exactly what is still wanted.
      filtering
      onSearchTextChange={setQuery}
      searchBarPlaceholder="Search branches, or type a new name"
      navigationTitle={`Worktree · ${project.name}`}
    >
      <List.EmptyView
        icon={Icon.Tree}
        title={typed ? `Create branch ${typed}` : "No branches"}
        description={typed ? "Press Enter to create the worktree." : "This repository has no branches to open."}
        actions={
          canCreate ? (
            <ActionPanel>
              <CreateActions project={project} branch={typed} />
            </ActionPanel>
          ) : undefined
        }
      />

      {sections.map(({ kind, rows }) => {
        return (
          <List.Section key={kind} title={KIND[kind].section} subtitle={String(rows.length)}>
            {rows.map((branch) => (
              <List.Item
                key={`${kind}:${branch.name}`}
                id={`${kind}:${branch.name}`}
                title={branch.name}
                subtitle={branch.subject}
                icon={{ source: KIND[kind].icon, tintColor: KIND[kind].color }}
                accessories={[
                  { text: branch.lastCommit },
                  { tag: { value: KIND[kind].tag, color: KIND[kind].color } },
                ]}
                actions={<BranchActions project={project} branch={branch} />}
              />
            ))}
          </List.Section>
        );
      })}

      {canCreate && (
        <List.Section title="New branch">
          <List.Item
            id={`create:${typed}`}
            title={`Create branch ${typed}`}
            icon={{ source: Icon.NewFolder, tintColor: Color.Magenta }}
            accessories={[{ tag: { value: "new", color: Color.Magenta } }]}
            actions={
              <ActionPanel>
                <CreateActions project={project} branch={typed} />
              </ActionPanel>
            }
          />
        </List.Section>
      )}
    </List>
  );
}

function BranchActions({ project, branch }: { project: Project; branch: Branch }) {
  // An existing worktree needs no `wt switch` at all — the checkout is already
  // on disk, so that path goes straight to the launch and stays instant, with
  // no progress Toast to show.
  const open = branch.worktreePath
    ? closeAfter(() => openDevWorkspace(branch.worktreePath as string), `Opening ${branch.name}`)
    : closeAfterProgress(
        (report) => launchWorktree({ repo: project.path, branch: branch.name, onProgress: report }),
        { start: `Opening ${branch.name}…`, hud: `Opening ${branch.name}` },
      );

  return (
    <ActionPanel>
      {/* One action, where there were two in a section of their own: the second
          ran `/start` in the agent pane the worktree used to be opened with.
          Tasks are started in T3 Code now, and this picker only opens a
          checkout — so there is nothing left to group. */}
      <Action title="Open Worktree" icon={Icon.Terminal} onAction={open} />
      <ActionPanel.Section title="Branch">
        <Action.CopyToClipboard title="Copy Branch Name" content={branch.name} shortcut={{ modifiers: ["ctrl"], key: "c" }} />
        {branch.worktreePath && <Action.ShowInFinder title="Open Worktree in File Manager" path={branch.worktreePath} />}
      </ActionPanel.Section>
    </ActionPanel>
  );
}

function CreateActions({ project, branch }: { project: Project; branch: string }) {
  return (
    <ActionPanel.Section>
      <Action
        title={`Create ${branch} and Open Worktree`}
        icon={Icon.NewFolder}
        onAction={closeAfterProgress(
          (report) => launchWorktree({ repo: project.path, branch, onProgress: report }),
          { start: `Creating ${branch}…`, hud: `Opening ${branch}` },
        )}
      />
    </ActionPanel.Section>
  );
}
