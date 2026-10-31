import SwiftUI

struct AccountView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var account: AccountService

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("Sync server") {
                TextField("https://your-server.example or http://100.x.x.x:8787", text: $account.serverURL)
                    .autocorrectionDisabledCompat()
                #if os(iOS)
                    .keyboardType(.URL)
                #endif
                Text("This is the small server from the SyncServer folder, running on your own machine. Your account and settings live there, not with anyone else.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if account.isSignedIn {
                Section("Signed in") {
                    Label(account.email ?? "Account", systemImage: "person.crop.circle.fill")
                    Button { Task { busy = true; await store.pullNow(); await store.pushNow(); busy = false } } label: {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(busy)
                    .hitTarget()
                    Button("Sign out", role: .destructive) { account.logout() }.hitTarget()
                }
                Section {
                    Text("Synced: machines, servers, mods and options. Not synced: passwords, the Tailscale key, and your EULA and mod acceptance. Those stay on each device, so enter machine passwords once on every device you use.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section("Account") {
                    TextField("Email", text: $email)
                        .autocorrectionDisabledCompat()
                    #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                    #endif
                    SecureField("Password (at least 10 characters)", text: $password)
                    HStack {
                        Button("Create account") { run(create: true) }
                            .buttonStyle(.borderedProminent)
                            .hitTarget()
                        Button("Sign in") { run(create: false) }
                            .buttonStyle(.bordered)
                            .hitTarget()
                        if busy { ProgressView() }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                }
            }

            if let errorText {
                Section { Label(errorText, systemImage: "exclamationmark.triangle.fill").font(.callout) }
            }
            if !account.status.isEmpty {
                Section { Text(account.status).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
    }

    private func run(create: Bool) {
        busy = true
        errorText = nil
        Task {
            do {
                if create { try await account.register(email: email, password: password) }
                else { try await account.login(email: email, password: password) }
                password = ""
                await store.pullNow()
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }
}
