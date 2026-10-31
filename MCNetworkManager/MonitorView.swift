import SwiftUI

struct MonitorView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var monitor: HostMonitor

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                ForEach(store.profile.hosts) { host in
                    HostCard(host: host, stats: monitor.stats[host.id])
                }
            }
            .padding()
        }
        .navigationTitle("Monitor")
        .onAppear { monitor.start(store: store) }
        .onDisappear { monitor.stop() }
    }
}

private struct HostCard: View {
    let host: Host
    let stats: HostStats?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let stats {
                    if stats.reachable {
                        Gauge(value: Double(stats.memUsedMB), in: 0...Double(max(stats.memTotalMB, 1))) {
                            Text("Memory")
                        } currentValueLabel: {
                            Text("\(stats.memUsedMB) / \(stats.memTotalMB) MB")
                        }
                        Gauge(value: Double(stats.diskPercent), in: 0...100) {
                            Text("Disk")
                        } currentValueLabel: {
                            Text("\(stats.diskPercent)%")
                        }
                        Label("Load \(stats.load1, specifier: "%.2f")", systemImage: "cpu")
                            .font(.callout)

                        Divider()

                        if stats.servers.isEmpty {
                            Text("No servers assigned to this machine.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(stats.servers) { server in
                            ServerRow(server: server)
                        }
                    } else {
                        Label(stats.error ?? "Not reachable", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                    }
                } else {
                    HStack { ProgressView(); Text("Connecting...").foregroundStyle(.secondary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(host.name, systemImage: "server.rack").font(.headline)
        }
    }
}

private struct ServerRow: View {
    let server: ServerStat

    private var running: Bool { server.state == "active" }

    var body: some View {
        HStack {
            // Shape + text, not colour alone.
            Image(systemName: running ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(running ? .green : .red)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(server.name.capitalized).font(.body.weight(.semibold))
                Text(running ? "Running" : server.state.capitalized)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                if let players = server.players {
                    Label("\(players)", systemImage: "person.2")
                } else if running {
                    Label("starting", systemImage: "hourglass")
                }
                if server.memoryMB > 0 {
                    Text("\(server.memoryMB) MB").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .accessibilityElement(children: .combine)
    }
}
