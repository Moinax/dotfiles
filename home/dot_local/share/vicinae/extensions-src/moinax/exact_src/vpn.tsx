import { Action, ActionPanel, Color, Icon, List } from "@vicinae/api";
import { disconnectVpns, downVpn, setVpn, vpns, type Vpn } from "./lib/system";
import { closeAfter, useLoader } from "./lib/ui";

/**
 * Mod+Ctrl+N, and the waybar shield's click — the replacement for the plain
 * Tailscale on/off toggle both used to run.
 *
 * A toggle was enough while there was one tunnel. With two that exclude each
 * other there are four transitions and no obvious default, so the list shows
 * which one is up and makes the switch one keypress from either row.
 *
 * Every action closes the launcher, the way keyboard-layout and audio-output do
 * rather than the way monitors does: you are on one VPN at a time, so the choice
 * ends the interaction. It closes *immediately*, without waiting for the switch:
 * `netbird up` on an expired token opens a browser for the SSO login, and the
 * window used to hold its progress toast right on top of that page, so finishing
 * the login meant closing the launcher by hand first. The switch runs detached
 * and reports itself on the waybar shield — pulsing while it is in flight — which
 * is where the result was going to be read anyway.
 */
export default function Command() {
  const { rows, isLoading, refresh } = useLoader<Vpn>(vpns, "Could not read VPN state");

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
                  onAction={closeAfter(() => downVpn(vpn.id), `Disconnecting ${vpn.label}…`)}
                />
              ) : (
                <Action
                  title={`Connect ${vpn.label}`}
                  icon={Icon.Lock}
                  onAction={closeAfter(() => setVpn(vpn.id), `Connecting ${vpn.label}…`)}
                />
              )}
              <Action
                title="Disconnect All"
                icon={Icon.LockDisabled}
                style="destructive"
                shortcut={{ modifiers: ["ctrl"], key: "d" }}
                onAction={closeAfter(disconnectVpns, "Disconnecting…")}
              />
              <Action title="Refresh" icon={Icon.ArrowClockwise} shortcut={{ modifiers: ["ctrl"], key: "r" }} onAction={refresh} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
