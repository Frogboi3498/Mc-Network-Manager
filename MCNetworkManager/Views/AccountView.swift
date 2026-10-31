import SwiftUI

struct AccountView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let session = app.session {
                    SignedInCard(session: session)
                } else {
                    SignInCard()
                }
                PrivacyNote()
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Account")
    }
}

// MARK: - Signed out

private struct SignInCard: View {
    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign in"
        case create = "Create account"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @AppStorage("syncServerURL") private var serverURL = ""
    @State private var mode: Mode = .signIn
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var inviteCode = ""
    @State private var busy = false
    @FocusState private var focus: Field?

    private enum Field { case server, username, password, confirm, invite }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sync your setup")
                .font(.title2.weight(.semibold))
            Text("Create an account to keep your nodes and network plan on every device you use. Skip it and everything stays on this Mac.")
                .foregroundStyle(.secondary)

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Sign in or create account")

            Form {
                TextField("Sync server", text: $serverURL, prompt: Text("http://100.x.x.x:8787"))
                    .focused($focus, equals: .server)
                    .autocorrectionDisabled()
                    .help("The address of your MC Network Manager sync server")
                if let warning = SyncClient.transportWarning(for: serverURL) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                TextField("Username", text: $username)
                    .focused($focus, equals: .username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .focused($focus, equals: .password)
                if mode == .create {
                    SecureField("Confirm password", text: $confirm)
                        .focused($focus, equals: .confirm)
                    TextField("Invite code (if the server needs one)", text: $inviteCode)
                        .focused($focus, equals: .invite)
                        .autocorrectionDisabled()
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            if mode == .create {
                Label("Your password cannot be reset. If you forget it, the saved data cannot be recovered.",
                      systemImage: "key.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(mode.rawValue) { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || busy)
            }
        }
        .onAppear { focus = serverURL.isEmpty ? .server : .username }
    }

    private var canSubmit: Bool {
        guard !serverURL.trimmingCharacters(in: .whitespaces).isEmpty,
              !username.trimmingCharacters(in: .whitespaces).isEmpty,
              !password.isEmpty else { return false }
        return mode == .signIn || (password == confirm && password.count >= 8)
    }

    private func submit() {
        busy = true
        let user = username.trimmingCharacters(in: .whitespaces)
        Task {
            let ok: Bool
            if mode == .create {
                ok = await app.register(serverURL: serverURL, username: user, password: password, inviteCode: inviteCode)
            } else {
                ok = await app.login(serverURL: serverURL, username: user, password: password)
            }
            busy = false
            if ok { password = ""; confirm = "" }
        }
    }
}

// MARK: - Signed in

private struct SignedInCard: View {
    @Environment(AppModel.self) private var app
    let session: AccountSession
    @State private var confirmingDelete = false
    @State private var deletePassword = ""
    @State private var deleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.username).font(.title2.weight(.semibold))
                    Text(session.serverURL).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Status", value: statusText)
                    LabeledContent("Nodes", value: "\(app.vault.nodes.count)")
                    LabeledContent("Servers", value: "\(app.vault.plan.servers.count)")
                    LabeledContent("Version", value: "\(session.revision)")
                }
                .padding(4)
            }

            HStack {
                Button { Task { await app.syncNow() } } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(app.syncState == .syncing)
                Spacer()
                Button("Sign out") { Task { await app.logout() } }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Delete account").font(.headline)
                Text("Removes your account and its saved data from the server. Data on your devices is kept.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Delete account...", role: .destructive) { confirmingDelete = true }
            }
        }
        .sheet(isPresented: $confirmingDelete) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Delete \(session.username)?").font(.title3.weight(.semibold))
                Text("Enter your password to confirm. This cannot be undone.")
                    .foregroundStyle(.secondary)
                SecureField("Password", text: $deletePassword)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    if deleting { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel", role: .cancel) { confirmingDelete = false; deletePassword = "" }
                        .keyboardShortcut(.cancelAction)
                    Button("Delete account", role: .destructive) {
                        deleting = true
                        Task {
                            let ok = await app.deleteAccount(password: deletePassword)
                            deleting = false
                            if ok { confirmingDelete = false }
                            deletePassword = ""
                        }
                    }
                    .disabled(deletePassword.isEmpty || deleting)
                }
            }
            .padding(24)
            .frame(width: 400)
        }
    }

    private var statusText: String {
        switch app.syncState {
        case .localOnly: return "Not syncing"
        case .idle(let date):
            guard let date else { return "Up to date" }
            return "Synced \(date.formatted(.relative(presentation: .named)))"
        case .syncing: return "Syncing..."
        case .failed(let m): return "Failed: \(m)"
        }
    }
}

private struct PrivacyNote: View {
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("How your data is protected", systemImage: "lock.shield")
                    .font(.headline)
                Text("Your node logins and network plan are encrypted on this device with a key made from your password (PBKDF2 and AES-256-GCM) before anything is uploaded. The sync server only stores the encrypted data and cannot read it. Your password never leaves this device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }
}
