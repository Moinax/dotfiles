import { Action, ActionPanel, Icon, List } from "@vicinae/api";
import { desktopApps, launchDesktopApp, type DesktopApp } from "./lib/system";
import { closeAfter, useLoader } from "./lib/ui";

/**
 * Mod+Alt+C — the Browser picker's shape, for chat apps.
 *
 * `Categories=*InstantMessaging` is the whole definition, so Slack, Discord,
 * Telegram and the two web-app shells appear without being named anywhere.
 * This is the pick-one door; opening all four at once is Mod+C, which runs
 * `chats` directly and ships no desktop entry precisely so that it does not
 * turn up here as a row.
 */
export default function Command() {
  const { rows, isLoading } = useLoader<DesktopApp>(
    () => desktopApps("InstantMessaging"),
    "Could not list chat apps",
  );

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search chat apps" navigationTitle="Chat">
      <List.EmptyView icon={Icon.SpeechBubble} title="No chat apps found" description="No desktop entry declares Categories=InstantMessaging." />
      {rows.map((app) => (
        <List.Item
          key={app.id}
          id={app.id}
          title={app.name}
          // The desktop entry's own Icon= value: either a themed icon name or
          // an absolute path for the shells that ship their own hicolor PNG.
          icon={{ source: app.icon || Icon.SpeechBubble, fallback: Icon.SpeechBubble }}
          keywords={[app.id]}
          actions={
            <ActionPanel>
              <Action
                title="Open Chat App"
                icon={Icon.SpeechBubble}
                onAction={closeAfter(() => launchDesktopApp(app.id), app.name)}
              />
              <Action.CopyToClipboard
                title="Copy Desktop Id"
                content={app.id}
                shortcut={{ modifiers: ["ctrl"], key: "c" }}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
