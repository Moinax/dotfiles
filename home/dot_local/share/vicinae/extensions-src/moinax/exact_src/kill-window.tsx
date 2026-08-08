import { Action, ActionPanel, Color, Icon, List } from "@vicinae/api";
import { closeWindow, killWindow, windows, type HyprWindow } from "./lib/system";
import { actionRunner, useLoader } from "./lib/ui";

/**
 * Mod+Escape — the replacement for rofi-killwindow.
 *
 * rofi could only offer one verb, and it chose the violent one: every selection
 * went straight to `kill -9`, losing unsaved work in whatever was picked. Here
 * Enter asks the window to close through the compositor — the same path as
 * clicking its ✕ — and SIGKILL is a separate action, marked destructive, for
 * the windows that ignore it.
 *
 * Closing also no longer ends the command. A window that refuses to go away is
 * exactly the case where you want a second attempt, and the list refreshes in
 * place so you can see whether the first one worked.
 */
export default function Command() {
  const { rows, isLoading, refresh } = useLoader<HyprWindow>(windows, "Could not list windows");
  // 150ms: the compositor retires a window slightly after `closewindow`
  // returns, so an immediate re-read still lists the row that was just closed.
  const act = actionRunner(refresh, 150);

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search windows" navigationTitle="Kill Window">
      <List.EmptyView icon={Icon.AppWindow} title="No windows open" />
      {rows.map((win) => (
        <List.Item
          key={win.address}
          id={win.address}
          title={win.class}
          subtitle={win.title}
          // The desktop-entry icon name is the window class lowercased — the
          // same resolution rofi-killwindow fed to rofi's `\0icon\x1f` field.
          icon={{ source: win.class.toLowerCase(), fallback: Icon.AppWindow }}
          keywords={[win.title, String(win.pid), win.workspace]}
          accessories={[
            { text: `ws ${win.workspace}` },
            { tag: { value: `pid ${win.pid}`, color: Color.SecondaryText } },
          ]}
          actions={
            <ActionPanel>
              <Action
                title="Close Window"
                icon={Icon.XMarkCircle}
                onAction={act(`Closed ${win.class}`, () => closeWindow(win.address))}
              />
              <Action
                title="Force Kill (SIGKILL)"
                icon={Icon.Bolt}
                style="destructive"
                shortcut={{ modifiers: ["ctrl", "shift"], key: "return" }}
                onAction={act(`Killed ${win.class} (${win.pid})`, () => killWindow(win.pid))}
              />
              <Action title="Refresh" icon={Icon.ArrowClockwise} shortcut={{ modifiers: ["ctrl"], key: "r" }} onAction={refresh} />
              <Action.CopyToClipboard title="Copy Window Class" content={win.class} shortcut={{ modifiers: ["ctrl"], key: "c" }} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
