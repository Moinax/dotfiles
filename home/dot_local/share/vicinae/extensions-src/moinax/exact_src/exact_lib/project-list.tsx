import { Action, ActionPanel, Color, Icon, List } from "@vicinae/api";
import { useEffect, useState } from "react";
import { repoStatus, type RepoStatus } from "./git";
import { openDevWorkspace } from "./launch";
import { listProjects, type Project } from "./projects";
import { BranchList } from "./branch-list";
import { closeAfter, useLoader } from "./ui";

/**
 * The project picker.
 *
 * rofi needed two near-identical scripts here (rofi-dev and the first half of
 * rofi-wts) because a rofi mode can only return a string: the choice of "open
 * the checkout" versus "go to the worktrees" had to be encoded as an exit code
 * and re-dispatched by the caller. An ActionPanel collapses that into one list
 * with two named actions — which is also why there is now a single command
 * rather than a Dev/Worktree pair. Two commands only existed to put a different
 * action on Enter, and the panel already does that without a second entrypoint.
 */
export function ProjectList() {
  const { rows: projects, isLoading } = useLoader<Project>(listProjects, "Could not list projects");
  const [selected, setSelected] = useState<string | null>(null);

  return (
    <List
      isLoading={isLoading}
      isShowingDetail
      onSelectionChange={setSelected}
      searchBarPlaceholder="Search projects"
      navigationTitle="Dev Project"
    >
      <List.EmptyView
        icon={Icon.Folder}
        title="No projects found"
        description="dev-projects found no git repositories under the projects root."
      />
      {projects.map((project) => (
        <List.Item
          key={project.entry}
          id={project.entry}
          title={project.name}
          subtitle={project.group}
          icon={{ source: Icon.Code, tintColor: Color.Blue }}
          // The full entry is a keyword so typing "labs/pack" still matches a
          // row whose visible title is just "pack".
          keywords={[project.entry, project.path]}
          detail={<ProjectDetail project={project} isSelected={selected === project.entry} />}
          actions={<ProjectActions project={project} />}
        />
      ))}
    </List>
  );
}

function ProjectActions({ project }: { project: Project }) {
  return (
    <ActionPanel>
      {/* Enter runs the first action and Shift+Enter the second by default, so
          the declaration below changes nothing today. It is there because the
          detail panel now advertises ⇧↵ in writing: a printed shortcut that
          rests on a host default is a promise this file does not keep. */}
      <ActionPanel.Section>
        <Action
          title="Open Dev Workspace"
          icon={Icon.Terminal}
          onAction={closeAfter(() => openDevWorkspace(project.path), `Opening ${project.name}`)}
        />
        <Action.Push
          title="Open Worktree…"
          icon={Icon.Tree}
          shortcut={{ modifiers: ["shift"], key: "return" }}
          target={<BranchList project={project} />}
        />
      </ActionPanel.Section>
      <ActionPanel.Section title="Project">
        <Action.CopyToClipboard title="Copy Path" content={project.path} shortcut={{ modifiers: ["ctrl"], key: "c" }} />
        <Action.ShowInFinder title="Open in File Manager" path={project.path} />
      </ActionPanel.Section>
    </ActionPanel>
  );
}

/**
 * Side panel for the highlighted project.
 *
 * The git calls fire only while this project is the selected one, which is why
 * the whole thing is gated on `isSelected` rather than rendered eagerly for
 * every row: thirty repositories' worth of `git status` on open is exactly the
 * per-row cost that has to be multiplied before being called cheap.
 */
function ProjectDetail({ project, isSelected }: { project: Project; isSelected: boolean }) {
  const [status, setStatus] = useState<RepoStatus | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (!isSelected || status) return;
    let cancelled = false;
    repoStatus(project.path)
      .then((repo) => !cancelled && setStatus(repo))
      .catch(() => !cancelled && setFailed(true));
    return () => {
      cancelled = true;
    };
  }, [isSelected, project.path, status]);

  if (failed) {
    return <List.Item.Detail markdown={`## ${project.name}\n\nCould not read git status for \`${project.path}\`.`} />;
  }

  return (
    <List.Item.Detail
      isLoading={isSelected && !status}
      markdown={`## ${project.name}\n\n\`${project.path}\``}
      metadata={
        status ? (
          <List.Item.Detail.Metadata>
            <List.Item.Detail.Metadata.Label title="Branch" text={status.branch} icon={Icon.Git} />
            <List.Item.Detail.Metadata.Label
              title="Working tree"
              text={status.dirtyCount === 0 ? "clean" : `${status.dirtyCount} changed`}
            />
            {/* The count and the way to reach it, on one line. The footer only
                ever advertises the primary action — a second one stays
                invisible there even with an explicit `shortcut` (measured) —
                and the ActionPanel that does list it is itself behind Ctrl+B.
                So Shift+Enter gets named next to the thing it opens. */}
            <List.Item.Detail.Metadata.TagList title="Worktrees">
              <List.Item.Detail.Metadata.TagList.Item
                text={String(status.worktreeCount)}
                color={status.worktreeCount > 0 ? Color.Green : Color.SecondaryText}
              />
              <List.Item.Detail.Metadata.TagList.Item text="⇧ ↵" color={Color.SecondaryText} />
            </List.Item.Detail.Metadata.TagList>
            <List.Item.Detail.Metadata.Separator />
            <List.Item.Detail.Metadata.Label title="Last commit" text={status.lastCommit} />
          </List.Item.Detail.Metadata>
        ) : undefined
      }
    />
  );
}
