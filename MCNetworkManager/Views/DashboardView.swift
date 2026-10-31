import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var app
    @Environment(MonitorModel.self) private var monitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if app.vault.nodes.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to monitor yet", systemImage: "gauge.with.dots.needle.67percent")
                    } description: {
                        Text("Add your nodes, then install your network. Live status appears here.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    PlayersCard()
                    ForEach(app.vault.nodes) { node in
                        NodeStatusCard(node: node)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem {
                Button { Task { await monitor.refresh(vault: app.vault) } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(monitor.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh now")
            }
        }
        // Refreshes right away, then every 20 seconds while this screen is open.
        .task(id: app.vault.nodes.count) {
            while !Task.isCancelled {
                await monitor.refresh(vault: app.vault)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }
}

// MARK: - Players

private struct PlayersCard: View {
    @Environment(AppModel.self) private var app
    @Environment(MonitorModel.self) private var monitor

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let proxy = app.vault.node(app.vault.plan.proxyNodeID) {
                    row(title: "Join address", host: proxy.host, port: app.vault.plan.publicPort, emphasize: true)
                }
                ForEach(app.vault.plan.servers) { server in
                    if let node = app.vault.node(server.nodeID) {
                        row(title: server.name.capitalized, host: node.host, port: server.port, emphasize: false)
                    }
                }
                if app.vault.plan.servers.isEmpty && app.vault.plan.proxyNodeID == nil {
                    Text("Set up your network to see player counts.").foregroundStyle(.secondary)
                }
            }
            .padding(6)
        } label: {
            Label("Players", systemImage: "person.2.fill").font(.headline)
        }
    }

    @ViewBuilder
    private func row(title: String, host: String, port: Int, emphasize: Bool) -> some View {
        let result = monitor.players[MonitorModel.pingKey(host: host, port: port)]
        HStack {
            Circle().fill(color(result)).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(title).font(emphasize ? .headline : .body)
            Spacer()
            switch result {
            case .success(let status):
                Text("\(status.online)/\(status.max) online").monospacedDigit()
                Text("\(status.latencyMS) ms").foregroundStyle(.secondary).monospacedDigit()
            case .failure(let error):
                Text(error.localizedDescription).foregroundStyle(.secondary)
            case nil:
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func color(_ result: Result<MinecraftStatus, PingError>?) -> Color {
        switch result {
        case .success: return .green
        case .failure: return .red
        case nil: return .gray
        }
    }
}

// MARK: - Node

private struct NodeStatusCard: View {
    @Environment(AppModel.self) private var app
    @Environment(MonitorModel.self) private var monitor
    let node: NodeProfile
    @State private var working: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let snap = monitor.snapshots[node.id] {
                    if let error = snap.error {
                        Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                    } else {
                        metrics(snap)
                        if !snap.services.isEmpty { Divider(); services(snap) }
                        else { Text("No Minecraft services found. Run the install first.").foregroundStyle(.secondary) }
                    }
                } else if !node.isComplete {
                    Label("Fill in this node's login on the Nodes screen.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Connecting...") }
                }
            }
            .padding(6)
        } label: {
            HStack {
                Label(node.displayName, systemImage: "server.rack").font(.headline)
                Spacer()
                if let ts = monitor.snapshots[node.id]?.tailscaleIP, !ts.isEmpty {
                    Text("Tailscale \(ts)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func metrics(_ s: NodeSnapshot) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                stat("Load", s.load.isEmpty ? "-" : s.load)
                stat("Disk used", s.disk.isEmpty ? "-" : s.disk)
                stat("Up", s.uptime.isEmpty ? "-" : s.uptime)
            }
            if let fraction = s.memoryPercent {
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Memory").font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: fraction)
                            .tint(fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .accentColor)
                        Text("\(s.memory.replacingOccurrences(of: "/", with: " of ")) MB")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .gridCellColumns(3)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private func services(_ s: NodeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(s.services) { service in
                HStack {
                    Image(systemName: service.isActive ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(service.isActive ? .green : .red)
                        .accessibilityHidden(true)
                    Text(service.name == "proxy" ? "Proxy" : service.name.capitalized)
                    Text(service.state).foregroundStyle(.secondary).font(.callout)
                    Spacer()
                    if working == service.name {
                        ProgressView().controlSize(.small)
                    } else {
                        Menu {
                            ForEach(ServiceAction.allCases) { action in
                                Button(action.title) { run(action, service.name) }
                            }
                        } label: {
                            Label("Control", systemImage: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    if service.name == "survival" || service.name.contains("map") {
                        if let url = URL(string: "http://\(node.host):8100") {
                            Link(destination: url) { Label("Map", systemImage: "map") }
                                .help("Open the BlueMap web map (if installed)")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func run(_ action: ServiceAction, _ service: String) {
        working = service
        Task {
            if let error = await monitor.control(action, service: service, on: node) { app.lastError = error }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await monitor.refresh(vault: app.vault)
            working = nil
        }
    }
}
