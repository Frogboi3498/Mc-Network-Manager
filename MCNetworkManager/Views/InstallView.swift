import SwiftUI

struct InstallView: View {
    @Environment(AppModel.self) private var app
    @Environment(ProvisionRunner.self) private var runner

    @State private var acceptedEULA = false
    @State private var acceptedMods = false
    @State private var tailscaleKey = ""
    /// Mods the person unticked on this screen. Applies to this install only.
    @State private var excluded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if runner.phase == .idle {
                review
            } else {
                progress
            }
        }
        .navigationTitle("Install")
    }

    // MARK: Review and consent

    private var problems: [String] { PlanValidator.problems(in: app.vault) }
    private var mods: [String] { Provisioner.optionalMods(in: app.vault) }

    /// The plan with this screen's unticked mods removed. This is what gets installed.
    private var effective: Vault {
        var v = app.vault
        for i in v.plan.servers.indices { v.plan.servers[i].optionalMods.removeAll { excluded.contains($0) } }
        return v
    }
    private var chosenMods: [String] { mods.filter { !excluded.contains($0) } }

    private var review: some View {
        Form {
            if !problems.isEmpty {
                Section("Fix these first") {
                    ForEach(problems, id: \.self) {
                        Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }

            Section("What will be installed") {
                if let jobs = try? Provisioner.jobs(for: effective, options: ProvisionOptions(acceptedEULA: true)) {
                    ForEach(jobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.node.displayName).font(.headline)
                            ForEach(job.summary, id: \.self) { Text("• \($0)").foregroundStyle(.secondary) }
                        }
                        .padding(.vertical, 2)
                    }
                } else {
                    Text("Complete the plan to see the install steps.").foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(ModCatalog.required) { item in
                    LabeledContent(item.title) { Text("Required").foregroundStyle(.secondary) }
                        .help(item.why)
                }
            } header: {
                Text("Always installed")
            } footer: {
                Text("Fabric API and FabricProxy-Lite are needed for the proxy to pass players to each server.")
            }

            Section {
                if mods.isEmpty {
                    Text("No optional mods selected.").foregroundStyle(.secondary)
                } else {
                    ForEach(mods, id: \.self) { slug in
                        Toggle(isOn: modBinding(slug)) {
                            VStack(alignment: .leading) {
                                Text(title(for: slug))
                                Text("on \(serversWith(slug))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !chosenMods.isEmpty {
                        Toggle("I agree to install the mods ticked above", isOn: $acceptedMods)
                            .font(.body.weight(.medium))
                    }
                }
            } header: {
                Text("Optional mods")
            } footer: {
                Text("These are downloaded from Modrinth when you install. Untick anything you do not want. Nothing optional is installed without your agreement.")
            }

            Section {
                Toggle(isOn: $acceptedEULA) {
                    Text("I accept the [Minecraft EULA](https://aka.ms/MinecraftEULA)")
                }
                if app.vault.plan.networking == .tailscale {
                    SecureField("Tailscale auth key (optional)", text: $tailscaleKey)
                    Text("Leave empty to sign in with a link shown during install. A key is used once and never saved.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button { start() } label: { Label("Install network", systemImage: "arrow.down.circle.fill") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canStart)
                }
            } footer: {
                Text("The installer connects over SSH and uses sudo. It is safe to run again if something fails, and existing worlds are never replaced.")
            }
        }
        .formStyle(.grouped)
    }

    private var canStart: Bool {
        problems.isEmpty && acceptedEULA && (chosenMods.isEmpty || acceptedMods)
    }

    private func start() {
        runner.start(vault: effective, options: ProvisionOptions(acceptedEULA: acceptedEULA, tailscaleAuthKey: tailscaleKey)) {
            app.vault.plan.lastProvisioned = Date()
            app.commit()
        }
        tailscaleKey = ""
    }

    private func title(for slug: String) -> String {
        ModCatalog.builtIn.first { $0.slug == slug }?.title ?? slug
    }

    private func serversWith(_ slug: String) -> String {
        app.vault.plan.servers.filter { $0.optionalMods.contains(slug) }.map(\.name).joined(separator: ", ")
    }

    private func modBinding(_ slug: String) -> Binding<Bool> {
        Binding(
            get: { !excluded.contains(slug) },
            set: { on in
                if on { excluded.remove(slug) } else { excluded.insert(slug) }
                acceptedMods = false   // the list changed, so ask again
            }
        )
    }

    // MARK: Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                switch runner.phase {
                case .running(let node):
                    ProgressView().controlSize(.small)
                    Text("Installing on \(node)...").font(.headline)
                case .finished(let ok):
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(ok ? .green : .red)
                    Text(ok ? "Your network is installed" : "The install did not finish").font(.headline)
                case .idle:
                    EmptyView()
                }
                Spacer()
                if runner.isRunning {
                    Button("Cancel", role: .cancel) { runner.cancel() }
                } else {
                    Button("Back") { acceptedMods = false; resetRunner() }
                }
            }

            if case .finished(true) = runner.phase, !runner.joinAddresses.isEmpty {
                GroupBox("Join address") {
                    ForEach(Array(Set(runner.joinAddresses)).sorted(), id: \.self) { address in
                        HStack {
                            Text(address).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button { Clipboard.copy(address) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        }
                        .padding(4)
                    }
                }
            }

            LogView(lines: runner.log)
        }
        .padding(20)
    }

    private func resetRunner() { runner.reset() }
}

struct LogView: View {
    let lines: [LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(color(line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(10)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func color(_ kind: LogLine.Kind) -> Color {
        switch kind {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        case .link: return .blue
        }
    }
}
