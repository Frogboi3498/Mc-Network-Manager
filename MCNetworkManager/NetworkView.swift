import SwiftUI

struct NetworkView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section {
                Text("Choose how friends reach the server. You can use both.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $store.profile.installTailscale) {
                    Label("Install and connect Tailscale", systemImage: "lock.shield")
                }
                Text("Works behind any router, with no port forwarding. Friends install Tailscale and you share the server with them, then they join using its Tailscale address (100.x.x.x). Tailscale Funnel cannot carry Minecraft traffic: it only listens on ports 443, 8443 and 10000 and only for TLS connections.")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.profile.installTailscale {
                    SecureField("Tailscale auth key (optional, never saved)", text: $store.tailscaleAuthKey)
                    Text("Leave this blank to get a sign-in link during the build.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Share a machine with friends (Tailscale)", destination: URL(string: "https://login.tailscale.com/admin/machines")!)
                        .hitTarget()
                }
            } header: { Text("Tailscale") }

            Section {
                Toggle(isOn: $store.profile.autoPortForward) {
                    Label("Forward the port automatically (UPnP)", systemImage: "arrow.left.arrow.right")
                }
                Text("Asks your router to open the proxy port, then reports your public address so friends can join without any extra software. This only works if your router has UPnP turned on and your internet provider gives you a real public address. If the build says CGNAT, use Tailscale instead.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Port forwarding") }

            Section {
                Text("If you prefer to do it by hand: forward TCP port \(store.profile.proxyPort) on your router to the machine that runs the proxy, then give friends your public IP address and that port.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Manual") }
        }
        .formStyle(.grouped)
        .navigationTitle("Network")
    }
}
