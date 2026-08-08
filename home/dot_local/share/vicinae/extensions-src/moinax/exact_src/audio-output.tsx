import { Action, ActionPanel, Color, Icon, List } from "@vicinae/api";
import { setDefaultSink, sinks, type Sink } from "./lib/system";
import { actionRunner, useLoader } from "./lib/ui";

/**
 * Mod+A — the replacement for the rofi menu inside toggle-audio-switch.sh.
 *
 * The old picker scraped `wpctl status` with sed over a box-drawing table and
 * then matched the chosen line back by substring, which selects the wrong sink
 * whenever one description contains another. This reads pactl's JSON, so the
 * row carries the sink name as data and the row you pick is the sink that gets
 * set. The current default is marked instead of being indistinguishable.
 */
export default function Command() {
  const { rows, isLoading, refresh } = useLoader<Sink>(sinks, "Could not list audio outputs");
  const act = actionRunner(refresh);

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search outputs" navigationTitle="Audio Output">
      <List.EmptyView icon={Icon.SpeakerOff} title="No audio outputs" description="pactl reported no sinks." />
      {rows.map((sink) => (
        <List.Item
          key={sink.name}
          id={sink.name}
          title={sink.description}
          icon={{
            source: sink.isDefault ? Icon.SpeakerHigh : Icon.Speaker,
            tintColor: sink.isDefault ? Color.Green : Color.SecondaryText,
          }}
          keywords={[sink.name]}
          accessories={sink.isDefault ? [{ tag: { value: "default", color: Color.Green } }] : undefined}
          actions={
            <ActionPanel>
              <Action
                title="Set as Default Output"
                icon={Icon.SpeakerHigh}
                onAction={act(`Output: ${sink.description}`, () => setDefaultSink(sink.name))}
              />
              <Action.CopyToClipboard title="Copy Sink Name" content={sink.name} shortcut={{ modifiers: ["ctrl"], key: "c" }} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
