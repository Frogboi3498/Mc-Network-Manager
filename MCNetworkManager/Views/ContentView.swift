import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard, network, nodes, install, files, terminals, account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .network: return "Network"
        case .nodes: return "Nodes"
        case .install: return "Install"
        case .files: return "Files"
        case .terminals: return "Terminals"
        case .account: return "Account"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .network: return "point.3.connected.trianglepath.dotted"
        case .nodes: return "server.rack"
        case .install: return "arrow.down.circle"
        case .files: return "folder"
        case .terminals: return "terminal"
        case .account: return "person.crop.circle"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: SidebarItem? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Manage") {
                    ForEach([SidebarItem.dashboard, .network, .nodes, .install]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("Tools") {
                    Label(SidebarItem.files.title, systemImage: SidebarItem.files.symbol)
                        .tag(SidebarItem.files)
                    Label(SidebarItem.terminals.title, systemImage: SidebarItem.terminals.symbol)
                        .tag(SidebarItem.terminals)
                }
                Section {
                    Label(SidebarItem.account.title, systemImage: SidebarItem.account.symbol)
                        .tag(SidebarItem.account)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            .safeAreaInset(edge: .bottom) { SyncBadge().padding(10) }
        } detail: {
            switch selection ?? .dashboard {
            case .dashboard: DashboardView()
            case .network: NetworkView()
            case .nodes: NodesView()
            case .install: InstallView()
            case .files: FilesView()
            case .terminals: TerminalsView()
            case .account: AccountView()
            }
        }
        .sheet(item: Binding(get: { app.syncChoice }, set: { app.syncChoice = $0 })) { choice in
            SyncChoiceSheet(choice: choice)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { app.lastError != nil },
            set: { if !$0 { app.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { app.lastError = nil }
        } message: {
            Text(app.lastError ?? "")
        }
    }
}

// MARK: - Sync badge

private struct SyncBadge: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tint: Color {
        switch app.syncState {
        case .localOnly: return .secondary
        case .idle: return .green
        case .syncing: return .blue
        case .failed: return .orange
        }
    }

    private var text: String {
        switch app.syncState {
        case .localOnly: return "Not signed in. Data stays on this Mac."
        case .idle(let date):
            guard let date else { return "Signed in as \(app.session?.username ?? "")" }
            return "Synced \(date.formatted(.relative(presentation: .named)))"
        case .syncing: return "Syncing..."
        case .failed(let message): return message
        }
    }
}

/// Shown when signing in on a Mac that already has its own settings.
struct SyncChoiceSheet: View {
    @Environment(AppModel.self) private var app
    let choice: SyncChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your account already has saved data", systemImage: "icloud.and.arrow.down")
                .font(.title2.weight(.semibold))
            Text("This Mac also has its own nodes and network plan. Pick which one to keep. The other copy is replaced.")
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                summary(title: "In your account", vault: choice.remote)
                summary(title: "On this Mac", vault: app.vault)
            }

            HStack {
                Spacer()
                Button("Keep this Mac's data") { Task { await app.resolve(useCloud: false) } }
                Button("Use my account's data") { Task { await app.resolve(useCloud: true) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .interactiveDismissDisabled()
    }

    private func summary(title: String, vault: Vault) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(vault.nodes.count) node\(vault.nodes.count == 1 ? "" : "s")")
                Text("\(vault.plan.servers.count) server\(vault.plan.servers.count == 1 ? "" : "s")")
                Text("Edited \(vault.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}
