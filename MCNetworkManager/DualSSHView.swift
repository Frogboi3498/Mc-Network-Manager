import SwiftUI

/// One terminal pane: which host it points at, plus its SSH session.
@MainActor
final class PaneModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var hostID: UUID?
    let session = SSHSession()

    init(hostID: UUID?) { self.hostID = hostID }
}

struct DualSSHView: View {
    @EnvironmentObject var store: AppStore
    @State private var panes: [PaneModel] = []

    private let maxPanes = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    addPane()
                } label: { Label("Add terminal", systemImage: "plus.rectangle.on.rectangle") }
                    .disabled(panes.count >= maxPanes)
                    .hitTarget()

                Button {
                    for pane in panes { connect(pane) }
                } label: { Label("Connect all", systemImage: "bolt.horizontal") }
                    .hitTarget()

                Spacer()
                Text("\(panes.count) of \(maxPanes)").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            GeometryReader { geo in
                let columns = geo.size.width > 700 ? min(max(panes.count, 1), 2) : 1
                let rows = max(1, Int((Double(panes.count) / Double(columns)).rounded(.up)))
                let spacing: CGFloat = 12
                let height = max(220, (geo.size.height - spacing * CGFloat(rows + 1)) / CGFloat(rows))

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) {
                        ForEach(panes) { pane in
                            PaneView(pane: pane, height: height, onClose: { remove(pane) }, onConnect: { connect(pane) })
                        }
                    }
                    .padding(spacing)
                }
            }
        }
        .navigationTitle("Terminals")
        .onAppear { seedPanes() }
    }

    private func seedPanes() {
        guard panes.isEmpty else { return }
        let hosts = store.profile.hosts
        panes = [PaneModel(hostID: hosts.first?.id), PaneModel(hostID: hosts.dropFirst().first?.id ?? hosts.first?.id)]
    }

    private func addPane() {
        guard panes.count < maxPanes else { return }
        panes.append(PaneModel(hostID: store.profile.hosts.first?.id))
    }

    private func remove(_ pane: PaneModel) {
        pane.session.disconnect()
        panes.removeAll { $0.id == pane.id }
    }

    private func connect(_ pane: PaneModel) {
        guard let id = pane.hostID, let host = store.host(id) else { return }
        pane.session.connect(host: host.sshAddress, user: host.username, password: store.password(for: host))
    }
}

private struct PaneView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var pane: PaneModel
    @ObservedObject private var session: SSHSession
    let height: CGFloat
    let onClose: () -> Void
    let onConnect: () -> Void

    init(pane: PaneModel, height: CGFloat, onClose: @escaping () -> Void, onConnect: @escaping () -> Void) {
        self.pane = pane
        self._session = ObservedObject(wrappedValue: pane.session)
        self.height = height
        self.onClose = onClose
        self.onConnect = onConnect
    }

    private var missingDetails: Bool {
        guard let id = pane.hostID, let host = store.host(id) else { return true }
        return host.sshAddress.isEmpty || host.username.isEmpty || store.password(for: host).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Machine", selection: $pane.hostID) {
                    ForEach(store.profile.hosts) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .disabled(session.isActive)

                statusLabel

                Spacer()

                if session.isActive {
                    Button("Disconnect") { session.disconnect() }.hitTarget()
                } else {
                    Button("Connect", action: onConnect).disabled(missingDetails).hitTarget()
                }
                Button(role: .destructive, action: onClose) { Image(systemName: "xmark") }
                    .accessibilityLabel("Close terminal")
                    .hitTarget()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)

            ZStack {
                TerminalContainer(session: session)
                if missingDetails && !session.isActive {
                    Text("Add this machine's address, username and password on the Setup tab.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch session.state {
        case .idle: Label("Offline", systemImage: "circle").font(.footnote).foregroundStyle(.secondary)
        case .connecting: Label("Connecting", systemImage: "hourglass").font(.footnote)
        case .connected: Label("Connected", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
        case .failed: Label("Failed", systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
        }
    }
}
