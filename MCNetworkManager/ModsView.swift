import SwiftUI

struct ModsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section {
                Text("These mods are downloaded from Modrinth (or the link you give) onto your servers when you press Build. Nothing is installed until you accept the list below.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            ForEach($store.profile.mods) { $mod in
                Section {
                    Toggle(isOn: $mod.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mod.title).font(.headline)
                            Text(mod.summary).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(mod.required)

                    HStack {
                        Text("Install on").foregroundStyle(.secondary)
                        Spacer()
                        ForEach(ServerRole.allCases) { role in
                            Toggle(role.title, isOn: Binding(
                                get: { mod.roles.contains(role) },
                                set: { on in
                                    if on { mod.roles.insert(role) } else { mod.roles.remove(role) }
                                }))
                            .toggleStyle(.button)
                            .disabled(mod.required)
                            .hitTarget()
                        }
                    }

                    if mod.isCustom {
                        TextField("Title", text: $mod.title)
                        TextField("Direct .jar download link", text: $mod.customURL)
                            .autocorrectionDisabledCompat()
                        Button("Remove", role: .destructive) {
                            store.profile.mods.removeAll { $0.id == mod.id }
                        }
                        .hitTarget()
                    }
                } footer: {
                    if mod.required { Text("Required for the network to work.") }
                }
            }

            Section {
                Button { store.addCustomMod() } label: { Label("Add a mod from a link", systemImage: "plus.circle") }
                    .hitTarget()
            }

            Section("Acceptance") {
                Toggle("Install the enabled mods on my servers", isOn: $store.modsAccepted)
                Text("Mods are third-party software. Only accept links you trust.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Mods")
    }
}
