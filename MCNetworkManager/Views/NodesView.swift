import SwiftUI

struct NodesView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Nodes are the Linux machines that will run your servers. The installer connects to them over SSH, so each needs an SSH login. A Debian or Ubuntu system with sudo works best.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if app.vault.nodes.isEmpty {
                    ContentUnavailableView {
                        Label("No nodes yet", systemImage: "server.rack")
                    } description: {
                        Text("Add the first machine to get started.")
                    } actions: {
                        Button("Add node") { add() }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ForEach($app.vault.nodes) { $node in
                        NodeCard(node: $node) { delete(node.id) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Nodes")
        .toolbar {
            ToolbarItem {
                Button { add() } label: { Label("Add node", systemImage: "plus") }
                    .help("Add a node")
            }
        }
        .onChange(of: app.vault.nodes) { _, _ in app.commit() }
    }

    private func add() {
        var node = NodeProfile()
        node.name = "node\(app.vault.nodes.count + 1)"
        app.vault.nodes.append(node)
    }

    private func delete(_ id: UUID) {
        app.vault.nodes.removeAll { $0.id == id }
        if app.vault.plan.proxyNodeID == id { app.vault.plan.proxyNodeID = nil }
        for i in app.vault.plan.servers.indices where app.vault.plan.servers[i].nodeID == id {
            app.vault.plan.servers[i].nodeID = nil
        }
    }
}

private struct NodeCard: View {
    @Binding var node: NodeProfile
    var onDelete: () -> Void

    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?
    @State private var confirmDelete = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Name", text: $node.name, prompt: Text("node1"))
                        .textFieldStyle(.plain)
                        .font(.headline)
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this node")
                    .accessibilityLabel("Remove \(node.displayName)")
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Host").foregroundStyle(.secondary)
                        HStack {
                            TextField("Host or IP address", text: $node.host).autocorrectionDisabled()
                            Text(":").foregroundStyle(.secondary)
                            TextField("Port", value: $node.port, format: .number.grouping(.never))
                                .frame(width: 70)
                        }
                    }
                    GridRow {
                        Text("Username").foregroundStyle(.secondary)
                        TextField("Username", text: $node.username).autocorrectionDisabled()
                    }
                    GridRow {
                        Text("Password").foregroundStyle(.secondary)
                        SecureField("Password", text: $node.password)
                    }
                }
                .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button { test() } label: { Label("Test connection", systemImage: "bolt.horizontal") }
                        .disabled(!node.isComplete || testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let result {
                        Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.ok ? .green : .red)
                            .font(.callout)
                            .lineLimit(3)
                    }
                    Spacer()
                }
            }
            .padding(6)
        }
        .confirmationDialog("Remove \(node.displayName)?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive, action: onDelete)
        } message: {
            Text("This only removes it from this app. Nothing is changed on the machine.")
        }
    }

    private func test() {
        testing = true
        result = nil
        let node = node
        Task {
            do {
                let out = try await SSHService.run(node, Shell.bash("uname -sm; id -u; command -v sudo >/dev/null && echo sudo=yes || echo sudo=no"), timeout: 15)
                let lines = out.split(whereSeparator: \.isNewline).map(String.init)
                let system = lines.first ?? "connected"
                let isRoot = lines.dropFirst().first == "0"
                let hasSudo = lines.contains("sudo=yes")
                if isRoot || hasSudo {
                    result = (true, "Connected: \(system)")
                } else {
                    result = (false, "Connected, but this user cannot use sudo or root. The installer needs it.")
                }
            } catch {
                result = (false, error.localizedDescription)
            }
            testing = false
        }
    }
}
