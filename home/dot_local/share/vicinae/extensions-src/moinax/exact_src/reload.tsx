import { Action, ActionPanel, Icon, List } from "@vicinae/api";
import { homedir } from "node:os";
import { capture } from "./lib/shell";
import { closeAfter } from "./lib/ui";

type ReloadAction = {
  title: string;
  detail: string;
  run: () => Promise<unknown>;
};

const home = homedir();
const actions: ReloadAction[] = [
  {
    title: "Reload Waybar",
    detail: "Restart the bar and reload its configuration",
    run: () => capture(`${home}/.config/hypr/scripts/reload-waybar.sh`),
  },
  {
    title: "Reload SwayNC",
    detail: "Reload the notification daemon configuration and CSS",
    run: async () => {
      await capture("swaync-client", ["-R"]);
      await capture("swaync-client", ["-rs"]);
    },
  },
  {
    title: "Reload Hyprland",
    detail: "Reload the compositor configuration",
    run: () => capture(`${home}/.config/hypr/scripts/reload-hyprland.sh`),
  },
];

export default function Command() {
  return (
    <List searchBarPlaceholder="Search reload actions" navigationTitle="Reload">
      {actions.map((item) => (
        <List.Item
          key={item.title}
          title={item.title}
          subtitle={item.detail}
          icon={Icon.ArrowClockwise}
          actions={
            <ActionPanel>
              <Action
                title={item.title}
                icon={Icon.ArrowClockwise}
                onAction={closeAfter(item.run, `${item.title} complete`)}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
