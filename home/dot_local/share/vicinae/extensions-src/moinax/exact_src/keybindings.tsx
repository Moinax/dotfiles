import { Action, ActionPanel, Color, Icon, List } from "@vicinae/api";
import { homedir } from "node:os";
import { useState } from "react";
import { captureLines } from "./lib/shell";
import { useLoader } from "./lib/ui";

/**
 * Mod+H — the Hyprland keybinding reference.
 *
 * The parser is not reimplemented. `hypr-keybindings` prints the parsed
 * bindings and exits; that script keeps the 200 lines of Lua-aware awk that
 * understand binds.lua — balanced parens, long strings, the `for i = 1, 7`
 * expansion — and stays the only thing that does. A TypeScript second copy
 * would be wrong about a different subset of the config within a month.
 *
 * This is the rendering half: sections with counts, the chord as a tag rather
 * than part of the row text, and a dropdown that filters to one section.
 */

type Binding = { section: string; combo: string; description: string };

/** `hypr-keybindings` emits `<section>\t<combo>\t<description>`. */
async function loadBindings(): Promise<Binding[]> {
  const lines = await captureLines(`${homedir()}/.local/bin/hypr-keybindings`);
  return lines.flatMap((line) => {
    const [section, combo, description] = line.split("\t");
    return section && combo ? [{ section, combo, description: description ?? "" }] : [];
  });
}

export default function Command() {
  const { rows: bindings, isLoading } = useLoader<Binding>(loadBindings, "Could not read keybindings");
  const [section, setSection] = useState("all");

  // Section order is the config's order, not alphabetical: binds.lua is written
  // in a deliberate sequence and reordering it here would make the two disagree.
  // A Set preserves insertion order, so it keeps that property.
  const sections = [...new Set(bindings.map((binding) => binding.section))];
  const visible = section === "all" ? sections : [section];

  return (
    <List
      isLoading={isLoading}
      searchBarPlaceholder="Search keybindings"
      navigationTitle="Keybindings"
      searchBarAccessory={
        <List.Dropdown tooltip="Section" value={section} onChange={setSection}>
          <List.Dropdown.Item title="All sections" value="all" />
          {sections.map((name) => (
            <List.Dropdown.Item key={name} title={name} value={name} />
          ))}
        </List.Dropdown>
      }
    >
      <List.EmptyView icon={Icon.Keyboard} title="No keybindings" description="hypr-keybindings returned nothing." />
      {visible.map((name) => {
        const rows = bindings.filter((binding) => binding.section === name);
        return (
          <List.Section key={name} title={name} subtitle={String(rows.length)}>
            {rows.map((binding, index) => (
              <List.Item
                key={`${name}:${binding.combo}:${index}`}
                id={`${name}:${binding.combo}:${index}`}
                title={binding.description}
                icon={{ source: Icon.Keyboard, tintColor: Color.Blue }}
                keywords={[binding.combo, name]}
                accessories={[{ tag: { value: binding.combo, color: Color.Magenta } }]}
                actions={
                  <ActionPanel>
                    <Action.CopyToClipboard title="Copy Shortcut" content={binding.combo} />
                    <Action.CopyToClipboard
                      title="Copy Shortcut and Description"
                      content={`${binding.combo} — ${binding.description}`}
                      shortcut={{ modifiers: ["ctrl", "shift"], key: "c" }}
                    />
                  </ActionPanel>
                }
              />
            ))}
          </List.Section>
        );
      })}
    </List>
  );
}
