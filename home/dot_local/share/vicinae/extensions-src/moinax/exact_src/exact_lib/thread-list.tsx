import { Action, ActionPanel, Color, Icon, List } from "@vicinae/api";
import { useCallback, useMemo, useState } from "react";
import type { Project } from "./projects";
import { focusT3Thread, isThreadLive, listT3Threads, newT3Thread, type T3Thread } from "./t3";
import { closeAfter, useLoader } from "./ui";

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
 * `projectId` is always a real id: registering a directory T3 Code has never
 * seen happens in the action that pushes this view. Doing it here as a mount
 * effect instead meant modelling `projectId: string | null`, and that one null
 * propagated into a registration ref, a second effect to re-read the list when
 * the id landed, a loading flag OR'd into the loader's own, a throw guarding
 * the create action and a conditional retry row — five compensations for a
 * state this view now never sees.
 */
export function ThreadList({ project, projectId }: { project: Project; projectId: string }) {
  const load = useCallback(() => listT3Threads(projectId), [projectId]);
  const { rows: threads, isLoading } = useLoader<T3Thread>(load, "Could not list threads");
  const [query, setQuery] = useState("");

  const typed = query.trim();
  const title = typed || "New thread";

  // The same trap `branch-list.tsx` documents: the list is uncontrolled and the
  // host does the filtering, so these rows never depend on the search text —
  // but declaring `onSearchTextChange` re-renders on every keystroke, and
  // without the memo each one discards every List.Item, its ActionPanel and a
  // fresh async closure per row. Typing a twelve-character name over ~18
  // threads throws away ~216 of them. The create row genuinely does depend on
  // what was typed, so it stays outside.
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
                  onAction={closeAfter(() => focusT3Thread(thread.thread_id), `Opening ${thread.title}`)}
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
      // Same reason as the branch list: declaring `onSearchTextChange` is what
      // makes the host hand through the unfiltered list, so `filtering` has to
      // be asked for again. The text is mirrored out only to name the thread
      // the create row would open.
      filtering
      onSearchTextChange={setQuery}
      searchBarPlaceholder="Search threads, or type a name to create one"
      navigationTitle={project.name}
    >
      <List.Section title="Create">
        <List.Item
          // Typing a name and pressing Enter is the whole interaction, so the
          // row has to say what it will be called — an unnamed thread is the
          // one you cannot find again an hour later.
          title={typed ? `New thread “${typed}”` : "New thread"}
          subtitle={typed ? undefined : "type a name first"}
          icon={{ source: Icon.Plus, tintColor: Color.Blue }}
          actions={
            <ActionPanel>
              <Action
                title="Create and Open"
                icon={Icon.Plus}
                onAction={closeAfter(
                  async () => focusT3Thread(await newT3Thread(projectId, title)),
                  `Opening ${title}`,
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
