import { Action, ActionPanel, Color, Icon, List } from "@vicinae/api";
import { blurVariants, setBlurVariant, type BlurVariant } from "./lib/system";
import { actionRunner, useLoader } from "./lib/ui";

/**
 * Mod+Alt+W — Hyprland 0.57's blur variants.
 *
 * Unlike the other single-choice pickers this one stays open: the point is to
 * compare variants, and the launcher is itself blurred (the vicinae-blur layer
 * rule), so each pick shows up right behind the list. Esc keeps the last one.
 */
export default function Command() {
  const { rows, isLoading, refresh } = useLoader<BlurVariant>(blurVariants, "Could not list blur variants");
  const act = actionRunner(refresh);

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search blur variants" navigationTitle="Blur Variant">
      <List.EmptyView icon={Icon.Droplets} title="No blur variants" description="Hyprland reported no decoration:blur:variant map." />
      {rows.map((variant) => (
        <List.Item
          key={variant.name}
          id={variant.name}
          title={variant.name}
          icon={{ source: Icon.Droplets, tintColor: variant.isActive ? Color.Green : Color.SecondaryText }}
          accessories={variant.isActive ? [{ tag: { value: "active", color: Color.Green } }] : undefined}
          actions={
            <ActionPanel>
              <Action
                title="Use This Variant"
                icon={Icon.Droplets}
                onAction={act(`Blur: ${variant.name}`, () => setBlurVariant(variant.name))}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
