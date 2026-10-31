import SwiftUI

struct NetworkView: View {
    @Environment(AppModel.self) private var app
    @State private var selectedServerID: UUID?
    @State private var showingEditServers = false

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Network") {
                TextField("Name", text: $app.vault.plan.name, prompt: Text("My Network"))
                TextField("Minecraft version", text: $app.vault.plan.minecraftVersion, prompt: Text("latest"))
                    .help("Use \"latest\" or a release such as 1.21.4")
                Picker("Proxy node", selection: $app.vault.plan.proxyNodeID) {
                    Text("Choose...").tag(UUID?.none)
                    ForEach(app.vault.nodes) { Text($0.displayName).tag(UUID?.some($0.id)) }
                }
                TextField("Join port", value: $app.vault.plan.publicPort, format: .number.grouping(.never))
                    .help("The one port players connect to")
            }

            // MARK: Servers section
            Section {
                if app.vault.plan.servers.isEmpty {
                    // Empty state – original buttons
                    HStack {
                        Button { addServer() } label: { Label("Add server", systemImage: "plus") }
                        Button("Use Lobby + Survival + Creative") { useTemplate() }
                    }
                } else {
                    // Tabs for each server
                    VStack(alignment: .leading, spacing: 12) {
                        // Tab picker
                        Picker("Server", selection: Binding(
                            get: { selectedServerID ?? app.vault.plan.servers.first?.id },
                            set: { selectedServerID = $0 }
                        )) {
                            ForEach(app.vault.plan.servers) { server in
                                Text(server.name.isEmpty ? "Server" : server.name)
                                    .tag(UUID?.some(server.id))
                            }
                        }
                        .pickerStyle(.segmented)

                        // Editor for the selected server
                        if let id = selectedServerID ?? app.vault.plan.servers.first?.id,
                           let index = app.vault.plan.servers.firstIndex(where: { $0.id == id }) {
                            ServerEditor(
                                server: $app.vault.plan.servers[index],
                                nodes: app.vault.nodes,
                                customMods: app.vault.customMods,
                                showDelete: false
                            ) {
                                // delete handled in the Edit Servers sheet
                            }
                        }

                        // Edit whole set
                        Button {
                            showingEditServers = true
                        } label: {
                            Label("Edit servers…", systemImage: "list.bullet.rectangle")
                        }
                    }
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("Players join the proxy and pick a server from the lobby. Each server runs Fabric.")
            }

            Section("Players") {
                Toggle("Only allow players on the whitelist", isOn: $app.vault.plan.whitelist)
                TextField("Your Minecraft username", text: $app.vault.plan.operatorName, prompt: Text("Operator (optional)"))
                Toggle("Make me operator on every server", isOn: $app.vault.plan.operatorOnAllServers)
                    .disabled(app.vault.plan.operatorName.isEmpty)
            }

            Section {
                Picker("Reach it from outside", selection: $app.vault.plan.networking) {
                    Text("Local network only").tag(NetworkingMode.none)
                    Text("Tailscale").tag(NetworkingMode.tailscale)
                    Text("Automatic port forwarding (UPnP)").tag(NetworkingMode.upnp)
                }
                switch app.vault.plan.networking {
                case .none:
                    EmptyView()
                case .tailscale:
                    TextField("Tailscale hostname", text: $app.vault.plan.tailscaleHostname, prompt: Text("Optional"))
                    Text("Installs Tailscale on the proxy node and signs it in. Friends join by installing Tailscale and accepting an invite to your tailnet (or you can share the machine with them from the Tailscale admin page). Nobody needs router changes.")
                        .font(.callout).foregroundStyle(.secondary)
                case .upnp:
                    Text("Asks your router to open the join port automatically. This only works if the router has UPnP turned on and your internet provider gives you a public address. If it does not work, use Tailscale or forward the port by hand.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Access from outside")
            }

            Section {
                Toggle("Copy Survival world into Creative every day", isOn: $app.vault.plan.syncSurvivalToCreative)
                    .disabled(PlanValidator.syncPair(in: app.vault) == nil)
                if PlanValidator.syncPair(in: app.vault) == nil {
                    Text("Needs a Survival and a Creative server on the same node.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("One way only: Survival into Creative. Creative is stopped for a moment while it copies at 04:00.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("World copy")
            }

            Section {
                CustomModsEditor(mods: $app.vault.customMods)
            } header: {
                Text("Extra mods")
            } footer: {
                Text("Add any mod by its Modrinth name (the last part of its web address). You choose which servers get it, and you confirm everything before install.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Network")
        .onChange(of: app.vault.plan) { _, _ in app.commit() }
        .onChange(of: app.vault.customMods) { _, _ in app.commit() }
        .onChange(of: app.vault.plan.servers) { _, newServers in
            // Keep selection valid
            if let id = selectedServerID, !newServers.contains(where: { $0.id == id }) {
                selectedServerID = newServers.first?.id
            }
            if selectedServerID == nil {
                selectedServerID = newServers.first?.id
            }
        }
        .sheet(isPresented: $showingEditServers) {
            EditServersSheet()
        }
    }

    private func addServer() {
        let used = Set(app.vault.plan.servers.map(\.port))
        var port = 30066
        while used.contains(port) { port += 1 }
        let node = app.vault.nodes.first?.id
        let newServer = ServerPlan(
            name: "server\(app.vault.plan.servers.count + 1)",
            gameMode: .survival,
            port: port,
            memoryMB: 2048,
            nodeID: node
        )
        app.vault.plan.servers.append(newServer)
        selectedServerID = newServer.id
    }

    private func useTemplate() {
        let node = app.vault.nodes.first?.id
        var template = NetworkPlan.template()
        template.servers = template.servers.map { var s = $0; s.nodeID = node; return s }
        app.vault.plan.servers = template.servers
        app.vault.plan.proxyNodeID = app.vault.plan.proxyNodeID ?? node
        selectedServerID = app.vault.plan.servers.first?.id
    }
}

// MARK: - Edit Servers Sheet (manage the whole set)

private struct EditServersSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            List {
                ForEach($app.vault.plan.servers) { $server in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Name", text: $server.name)
                        HStack {
                            Picker("Mode", selection: $server.gameMode) {
                                ForEach(GameMode.allCases) { Text($0.title).tag($0) }
                            }
                            TextField("Port", value: $server.port, format: .number.grouping(.never))
                                .frame(width: 80)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { indexSet in
                    app.vault.plan.servers.remove(atOffsets: indexSet)
                }
                .onMove { from, to in
                    app.vault.plan.servers.move(fromOffsets: from, toOffset: to)
                }

                Section {
                    Button {
                        addServer()
                    } label: {
                        Label("Add server", systemImage: "plus")
                    }
                    Button("Use Lobby + Survival + Creative") {
                        useTemplate()
                    }
                }
            }
            .navigationTitle("Edit Servers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
        .frame(minWidth: 420, minHeight: 380)
    }

    private func addServer() {
        let used = Set(app.vault.plan.servers.map(\.port))
        var port = 30066
        while used.contains(port) { port += 1 }
        let node = app.vault.nodes.first?.id
        app.vault.plan.servers.append(
            ServerPlan(name: "server\(app.vault.plan.servers.count + 1)", gameMode: .survival, port: port, memoryMB: 2048, nodeID: node)
        )
    }

    private func useTemplate() {
        let node = app.vault.nodes.first?.id
        var template = NetworkPlan.template()
        template.servers = template.servers.map { var s = $0; s.nodeID = node; return s }
        app.vault.plan.servers = template.servers
        app.vault.plan.proxyNodeID = app.vault.plan.proxyNodeID ?? node
    }
}

// MARK: - Server Editor

private struct ServerEditor: View {
    @Binding var server: ServerPlan
    let nodes: [NodeProfile]
    let customMods: [String]
    var showDelete: Bool = true
    var onDelete: () -> Void

    var body: some View {
        Group {
            Picker("Game mode", selection: $server.gameMode) {
                ForEach(GameMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Runs on", selection: $server.nodeID) {
                Text("Choose...").tag(UUID?.none)
                ForEach(nodes) { Text($0.displayName).tag(UUID?.some($0.id)) }
            }
            TextField("Port", value: $server.port, format: .number.grouping(.never))
            Stepper(value: $server.memoryMB, in: 512...65536, step: 512) {
                LabeledContent("Memory", value: "\(server.memoryMB) MB")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Optional mods").font(.subheadline).foregroundStyle(.secondary)
                ForEach(ModCatalog.builtIn) { mod in
                    modToggle(slug: mod.slug, title: mod.title)
                }
                ForEach(customMods, id: \.self) { slug in
                    modToggle(slug: slug, title: slug)
                }
            }
            if showDelete {
                Button("Remove server", role: .destructive, action: onDelete)
            }
        }
    }

    private func modToggle(slug: String, title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { server.optionalMods.contains(slug) },
            set: { on in
                if on { if !server.optionalMods.contains(slug) { server.optionalMods.append(slug) } }
                else { server.optionalMods.removeAll { $0 == slug } }
            }
        ))
    }
}

// MARK: - Custom Mods Editor

private struct CustomModsEditor: View {
    @Binding var mods: [String]
    @State private var draft = ""

    var body: some View {
        ForEach(mods, id: \.self) { slug in
            HStack {
                Text(slug)
                Spacer()
                Button { mods.removeAll { $0 == slug } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(slug)")
            }
        }
        HStack {
            TextField("Modrinth name", text: $draft, prompt: Text("e.g. lithium"))
                .autocorrectionDisabled()
                .onSubmit(add)
            Button("Add", action: add).disabled(!ModCatalog.isValidSlug(draft))
        }
    }

    private func add() {
        let slug = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard ModCatalog.isValidSlug(slug), !mods.contains(slug), !ModCatalog.builtIn.contains(where: { $0.slug == slug }) else { return }
        mods.append(slug)
        draft = ""
    }
}
