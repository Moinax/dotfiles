import { Action, ActionPanel, Color, Icon, List } from "@vicinae/api";
import { keyboardLayouts, setKeyboardLayout, type KeyboardLayout } from "./lib/system";
import { actionRunner, useLoader } from "./lib/ui";

/**
 * Mod+K — the replacement for the rofi menu inside toggle-keyboard-layout.sh.
 *
 * The rofi version listed three names and nothing else: it could not tell you
 * which layout you were already on, which is the one question you have when you
 * open it. Here the active one is marked and sorted to the top, and switching
 * refreshes in place so the mark moves where you can see it.
 */
export default function Command() {
  const { rows: layouts, isLoading, refresh } = useLoader<KeyboardLayout>(keyboardLayouts, "Could not list layouts");
  // The compositor picks the new input.lua up on its own; refreshing is only
  // so the "active" mark moves where you can see it.
  const act = actionRunner(refresh);

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
                onAction={act(`Layout: ${layout.name}`, () => setKeyboardLayout(layout.name))}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
