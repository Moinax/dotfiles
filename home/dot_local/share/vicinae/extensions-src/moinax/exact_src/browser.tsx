import { Action, ActionPanel, Color, Icon, List } from "@vicinae/api";
import { browsers, launchBrowser, type Browser } from "./lib/system";
import { closeAfter, useLoader } from "./lib/ui";

/**
 * Mod+Alt+B — the replacement for `browser-launch.sh pick`.
 *
 * The scan stays in the script (freedesktop crawl for `Categories=*WebBrowser`,
 * NoDisplay filtering, dedupe on display name) so that this and the plain
 * `Mod+B` default-browser path cannot disagree about what is installed. What is
 * new is that the system default is marked — rofi listed four identical-looking
 * rows with no way to tell which one `Mod+B` would have opened.
 */
export default function Command() {
  const { rows, isLoading } = useLoader<Browser>(browsers, "Could not list browsers");

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search browsers" navigationTitle="Browser">
      <List.EmptyView icon={Icon.Chrome} title="No browsers found" description="No desktop entry declares Categories=WebBrowser." />
      {rows.map((browser) => (
        <List.Item
          key={browser.id}
          id={browser.id}
          title={browser.name}
          // The desktop entry's own Icon= value: either a themed icon name or
          // an absolute path for the AppImage installs that ship their own.
          icon={{ source: browser.icon || Icon.Globe01, fallback: Icon.Globe01 }}
          keywords={[browser.id]}
          accessories={browser.isDefault ? [{ tag: { value: "default", color: Color.Green } }] : undefined}
          actions={
            <ActionPanel>
              <Action
                title="Open Browser"
                icon={Icon.Globe01}
                onAction={closeAfter(() => launchBrowser(browser.id), browser.name)}
              />
              <Action.CopyToClipboard
                title="Copy Desktop Id"
                content={browser.id}
                shortcut={{ modifiers: ["ctrl"], key: "c" }}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
