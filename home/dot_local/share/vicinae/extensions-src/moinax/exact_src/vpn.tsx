import { Action, ActionPanel, Color, Icon, List } from "@vicinae/api";
import { disconnectVpns, downVpn, setVpn, vpns, type Vpn } from "./lib/system";
import { actionRunner, useLoader } from "./lib/ui";

/**
 * Mod+Ctrl+N, and the waybar shield's click — the replacement for the plain
 * Tailscale on/off toggle both used to run.
 *
 * A toggle was enough while there was one tunnel. With two that exclude each
 * other there are four transitions and no obvious default, so the list shows
 * which one is up and makes the switch one keypress from either row.
 *
 * The launcher stays open the way it does for monitors: connecting one VPN
 * changes the other row too, and seeing that happen is the confirmation that
 * the exclusivity did what it claims.
 */
export default function Command() {
  const { rows, isLoading, refresh } = useLoader<Vpn>(vpns, "Could not read VPN state");
  const act = actionRunner(refresh);

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search VPNs" navigationTitle="VPN">
      <List.EmptyView icon={Icon.Lock} title="No VPN configured" />
      {rows.map((vpn) => (
        <List.Item
          key={vpn.id}
          id={vpn.id}
          title={vpn.label}
          subtitle={vpn.detail}
          icon={{
            source: vpn.connected ? Icon.Lock : Icon.LockDisabled,
            tintColor: vpn.connected ? Color.Green : Color.SecondaryText,
          }}
          accessories={[
            {
              tag: vpn.connected
                ? { value: "connected", color: Color.Green }
                : { value: "off", color: Color.SecondaryText },
            },
          ]}
          actions={
            <ActionPanel>
              {vpn.connected ? (
                <Action
                  title={`Disconnect ${vpn.label}`}
                  icon={Icon.LockDisabled}
                  style="destructive"
                  onAction={act(`Disconnected ${vpn.label}`, () => downVpn(vpn.id))}
                />
              ) : (
                <Action
                  title={`Connect ${vpn.label}`}
                  icon={Icon.Lock}
                  onAction={act(`Connected ${vpn.label}`, () => setVpn(vpn.id))}
                />
              )}
              <Action
                title="Disconnect All"
                icon={Icon.LockDisabled}
                style="destructive"
                shortcut={{ modifiers: ["ctrl"], key: "d" }}
                onAction={act("All VPNs disconnected", disconnectVpns)}
              />
              <Action title="Refresh" icon={Icon.ArrowClockwise} shortcut={{ modifiers: ["ctrl"], key: "r" }} onAction={refresh} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
