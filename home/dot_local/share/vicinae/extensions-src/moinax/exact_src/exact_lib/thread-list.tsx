import { Action, ActionPanel, Color, Icon, List } from "@vicinae/api";
import { useCallback, useMemo } from "react";
import type { Project } from "./projects";
import { focusT3Thread, isThreadLive, listT3Threads, openT3Draft, type T3Thread } from "./t3";
import { closeAfterProgress, useLoader } from "./ui";

/**
 * Session state, as the picker shows it.
 *
 * Only the live states and `error` get a mark of their own, in two colours. The
 * rest are the same thing to someone deciding which thread to open — nobody
 * picks differently for "interrupted" than for "stopped" — and a legend of
 * seven colours is a legend nobody reads.
 *
 * *Which* states count as live is `isThreadLive`'s call, not this table's: the
 * project list asks the same question about the same rows, and when each owned
 * its own answer they disagreed on `ready` immediately.
 */
const ERROR = { icon: Icon.Exclamationmark, color: Color.Red, tag: "error" };
const IDLE = { icon: Icon.Circle, color: Color.SecondaryText, tag: "idle" };

function stateOf(thread: T3Thread) {
  if (thread.status === "error") return ERROR;
  // The tag keeps the raw status so `running` and `ready` stay tellable apart;
  // only the colour is shared between them.
  if (isThreadLive(thread)) return { icon: Icon.CircleFilled, color: Color.Green, tag: thread.status };
  return IDLE;
}

/**
 * The threads of one project, and the way into a new one.
 *
 * An unregistered directory has no existing threads. Registration happens in
 * `t3 app` only when the user chooses New thread.
 */
export function ThreadList({ project, projectId }: { project: Project; projectId: string | null }) {
  const load = useCallback(() => projectId ? listT3Threads(projectId) : Promise.resolve([]), [projectId]);
  const { rows: threads, isLoading } = useLoader<T3Thread>(load, "Could not list threads");

  // Keep the existing-thread rows stable while the host filters the list.
  const rows = useMemo(
    () =>
      threads.map((thread) => {
        const state = stateOf(thread);
        return (
          <List.Item
            key={thread.thread_id}
            title={thread.title}
            // The blocked count earns the only other colour on the row: it is
            // the one state that means the thread is waiting on *you*.
            accessories={[
              ...(thread.pending > 0
                ? [{ tag: { value: `${thread.pending} waiting`, color: Color.Orange } }]
                : []),
              { tag: { value: state.tag, color: state.color } },
            ]}
            icon={{ source: state.icon, tintColor: state.color }}
            actions={
              <ActionPanel>
                <Action
                  title="Open Thread"
                  icon={Icon.ArrowRight}
                  // Progress rather than a plain close: with T3 Code down this
                  // waits out an Electron cold start, and the app paints
                  // nothing for its first 2-3s. Without a live toast the
                  // launcher just sits there looking wedged.
                  onAction={closeAfterProgress(() => focusT3Thread(thread.thread_id), {
                    start: `Opening ${thread.title}…`,
                  })}
                />
                <Action.CopyToClipboard
                  title="Copy Thread Id"
                  content={thread.thread_id}
                  shortcut={{ modifiers: ["ctrl"], key: "c" }}
                />
              </ActionPanel>
            }
          />
        );
      }),
    [threads],
  );

  return (
    <List
      isLoading={isLoading}
      searchBarPlaceholder="Search threads"
      navigationTitle={project.name}
    >
      <List.Section title="Create">
        <List.Item
          title="New thread"
          subtitle="Write your prompt in T3 Code"
          icon={{ source: Icon.Plus, tintColor: Color.Blue }}
          actions={
            <ActionPanel>
              <Action
                title="Open New Draft"
                icon={Icon.Plus}
                onAction={closeAfterProgress(
                  () => openT3Draft(project.path),
                  { start: "Opening new draft…" },
                )}
              />
            </ActionPanel>
          }
        />
      </List.Section>

      <List.Section title="Threads">{rows}</List.Section>
    </List>
  );
}
