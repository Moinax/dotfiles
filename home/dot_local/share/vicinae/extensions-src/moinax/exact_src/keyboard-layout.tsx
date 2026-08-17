import { Action, ActionPanel, Color, Icon, List } from "@vicinae/api";
import { keyboardLayouts, setKeyboardLayout, type KeyboardLayout } from "./lib/system";
import { closeAfter, useLoader } from "./lib/ui";

/**
 * Mod+K — the replacement for the rofi menu inside toggle-keyboard-layout.sh.
 *
 * The rofi version listed three names and nothing else: it could not tell you
 * which layout you were already on, which is the one question you have when you
 * open it. Here the active one is marked and sorted to the top.
 *
 * Switching closes the launcher: you are on one layout at a time, so the switch
 * ends the interaction, and the HUD is the confirmation the compositor cannot
 * give you.
 */
export default function Command() {
  const { rows: layouts, isLoading } = useLoader<KeyboardLayout>(keyboardLayouts, "Could not list layouts");

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search layouts" navigationTitle="Keyboard Layout">
      <List.EmptyView
        icon={Icon.Keyboard}
        title="No layouts"
        description="No .lua templates found in ~/.config/hypr/conf/input-layouts."
      />
      {layouts.map((layout) => (
        <List.Item
          key={layout.name}
          id={layout.name}
          title={layout.name}
          icon={{ source: Icon.Keyboard, tintColor: layout.isActive ? Color.Green : Color.SecondaryText }}
          accessories={layout.isActive ? [{ tag: { value: "active", color: Color.Green } }] : undefined}
          actions={
            <ActionPanel>
              <Action
                title="Switch to This Layout"
                icon={Icon.Keyboard}
                onAction={closeAfter(() => setKeyboardLayout(layout.name), `Layout: ${layout.name}`)}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
