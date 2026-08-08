import { Action, ActionPanel, Color, Icon, List, showToast, Toast } from "@vicinae/api";
import { monitors, toggleMonitor, type Monitor } from "./lib/system";
import { actionRunner, useLoader } from "./lib/ui";

/**
 * Mod+M — the replacement for the rofi menu inside toggle-monitors.sh.
 *
 * rofi could only draw the on/off state by prefixing each row with a ☑ or ☐
 * glyph inside the text, then parsing the chosen row back apart to recover the
 * output name. The state is a tag here and the name is the row's id, so nothing
 * has to be parsed back out of a label.
 *
 * Toggling also stops closing the launcher. Turning two outputs off is two
 * keypresses instead of two round trips, and the refusal to disable the last
 * active one arrives as a toast on a list that is still open.
 */
export default function Command() {
  const { rows: outputs, isLoading, refresh } = useLoader<Monitor>(monitors, "Could not list outputs");
  const act = actionRunner(refresh);

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search outputs" navigationTitle="Monitors">
      <List.EmptyView icon={Icon.Monitor} title="No connected outputs" />
      {outputs.map((output) => {
        return (
          <List.Item
            key={output.name}
            id={output.name}
            title={output.name}
            subtitle={output.description}
            icon={{
              source: output.enabled ? Icon.Monitor : Icon.MinusCircle,
              tintColor: output.enabled ? Color.Green : Color.SecondaryText,
            }}
            accessories={[
              ...(output.mode ? [{ text: output.mode }] : []),
              {
                tag: output.enabled
                  ? { value: "on", color: Color.Green }
                  : { value: "off", color: Color.SecondaryText },
              },
            ]}
            actions={
              <ActionPanel>
                <Action
                  title={output.enabled ? `Disable ${output.name}` : `Enable ${output.name}`}
                  icon={output.enabled ? Icon.MinusCircle : Icon.Monitor}
                  style={output.enabled ? "destructive" : undefined}
                  // `canDisable` comes from the script, which is also what
                  // enforces it — the UI reports the rule rather than holding a
                  // second copy of it.
                  onAction={
                    output.enabled && !output.canDisable
                      ? async () => {
                          await showToast({
                            style: Toast.Style.Failure,
                            title: `${output.name} is the last active output`,
                          });
                        }
                      : act(`${output.enabled ? "Disabled" : "Enabled"} ${output.name}`, () => toggleMonitor(output.name))
                  }
                />
                <Action title="Refresh" icon={Icon.ArrowClockwise} shortcut={{ modifiers: ["ctrl"], key: "r" }} onAction={refresh} />
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
