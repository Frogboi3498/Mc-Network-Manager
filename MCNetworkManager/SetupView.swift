import SwiftUI

struct SetupView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section {
                Text("Your servers are Linux machines (Debian or Ubuntu). The app connects over SSH and builds a Velocity proxy plus Fabric game servers on them. Add one machine, or two to spread the load.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach($store.profile.hosts) { $host in
                Section {
                    TextField("Name", text: $host.name)
                    TextField("SSH address (IP or hostname)", text: $host.sshAddress)
                        .autocorrectionDisabledCompat()
                    TextField("Address the proxy uses to reach this host (blank = same)", text: $host.backendAddress)
                        .autocorrectionDisabledCompat()
                    TextField("Username", text: $host.username)
                        .autocorrectionDisabledCompat()
                    SecureField("Password (kept on this device only)", text: Binding(
                        get: { store.password(for: host) },
                        set: { store.setPassword($0, for: host) }))
                    if store.profile.hosts.count > 1 {
                        Button("Remove this machine", role: .destructive) { store.removeHost(host) }
                            .hitTarget()
                    }
                } header: {
                    Label(host.name, systemImage: "server.rack")
                }
            }

            Section {
                Button { store.addHost() } label: { Label("Add another machine", systemImage: "plus.circle") }
                    .hitTarget()
            }

            Section("Game servers") {
                ForEach($store.profile.servers) { $server in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(server.role.title, systemImage: server.role.symbol).font(.headline)
                        Picker("Runs on", selection: $server.hostID) {
                            ForEach(store.profile.hosts) { Text($0.name).tag($0.id) }
                        }
                        HStack {
                            Text("Port")
                            Spacer()
                            TextField("Port", value: $server.port, format: .number.grouping(.never))
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                        }
                        Stepper("Memory: \(server.memoryGB) GB", value: $server.memoryGB, in: 1...64)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Proxy (the one address players join)") {
                Picker("Runs on", selection: $store.profile.proxyHostID) {
                    ForEach(store.profile.hosts) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Text("Public port")
                    Spacer()
                    TextField("Port", value: $store.profile.proxyPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                Text("Players join the lobby first and pick Survival or Creative with /server survival or /server creative.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Extras") {
                Toggle("Copy Survival world into Creative every night (one way)", isOn: $store.profile.syncSurvivalToCreative)
                Text("Only works when Survival and Creative run on the same machine. The Creative server restarts briefly during the copy.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("Operators (Minecraft usernames, comma separated)", text: $store.profile.operators)
                    .autocorrectionDisabledCompat()
                HStack {
                    Text("Operators on")
                    Spacer()
                    ForEach(ServerRole.allCases) { role in
                        Toggle(role.title, isOn: Binding(
                            get: { store.profile.opRoles.contains(role) },
                            set: { on in
                                if on { store.profile.opRoles.insert(role) } else { store.profile.opRoles.remove(role) }
                            }))
                        .toggleStyle(.button)
                        .hitTarget()
                    }
                }
                TextField("Lobby world download link (.zip, optional)", text: $store.profile.lobbyWorldURL)
                    .autocorrectionDisabledCompat()
            }

            Section("Minecraft EULA") {
                Toggle("I accept the Minecraft EULA", isOn: $store.eulaAccepted)
                Link("Read the EULA", destination: URL(string: "https://www.minecraft.net/en-us/eula")!)
                    .hitTarget()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
    }
}

extension View {
    func autocorrectionDisabledCompat() -> some View {
        #if os(iOS)
        return self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        return self.autocorrectionDisabled()
        #endif
    }
}
