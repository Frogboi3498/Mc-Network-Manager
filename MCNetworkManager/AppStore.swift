import Foundation
import SwiftUI

/// Single source of truth: the profile (synced), device-local secrets, and consent flags.
@MainActor
final class AppStore: ObservableObject {
    @Published var profile: Profile {
        didSet {
            guard !internalChange, profile != oldValue else { return }
            internalChange = true
            profile.updatedAt = Date()
            internalChange = false
            save()
            scheduleSync()
        }
    }

    /// Consent is per device on purpose: it is never synced.
    @Published var eulaAccepted: Bool {
        didSet { UserDefaults.standard.set(eulaAccepted, forKey: "eulaAccepted") }
    }
    @Published var modsAccepted: Bool {
        didSet { UserDefaults.standard.set(modsAccepted, forKey: "modsAccepted") }
    }

    /// Optional Tailscale auth key. Memory only; never stored or synced.
    @Published var tailscaleAuthKey: String = ""

    /// Host passwords, device-local (Keychain). Keyed by host id.
    @Published private var passwords: [UUID: String] = [:]

    weak var account: AccountService?

    private var internalChange = false
    private var syncTask: Task<Void, Never>?

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MCNetworkManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profile.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? Self.decoder.decode(Profile.self, from: data) {
            profile = saved
        } else {
            profile = Profile.makeDefault()
        }
        eulaAccepted = UserDefaults.standard.bool(forKey: "eulaAccepted")
        modsAccepted = UserDefaults.standard.bool(forKey: "modsAccepted")
        for host in profile.hosts {
            passwords[host.id] = Keychain.get("host-\(host.id.uuidString)") ?? ""
        }
    }

    // MARK: Passwords

    func password(for host: Host) -> String { passwords[host.id] ?? "" }

    func setPassword(_ value: String, for host: Host) {
        passwords[host.id] = value
        Keychain.set(value, for: "host-\(host.id.uuidString)")
    }

    // MARK: Hosts and servers

    func host(_ id: UUID) -> Host? { profile.hosts.first { $0.id == id } }

    func addHost() {
        let number = profile.hosts.count + 1
        profile.hosts.append(Host(name: "Server \(number)", sshAddress: "", backendAddress: "", username: ""))
    }

    func removeHost(_ host: Host) {
        guard profile.hosts.count > 1 else { return }
        let fallback = profile.hosts.first { $0.id != host.id }!.id
        profile.hosts.removeAll { $0.id == host.id }
        for i in profile.servers.indices where profile.servers[i].hostID == host.id {
            profile.servers[i].hostID = fallback
        }
        if profile.proxyHostID == host.id { profile.proxyHostID = fallback }
        Keychain.remove("host-\(host.id.uuidString)")
        passwords[host.id] = nil
    }

    func addCustomMod() {
        profile.mods.append(ModDef(
            id: "custom-\(UUID().uuidString.prefix(8).lowercased())",
            title: "Custom mod",
            summary: "Direct .jar download link.",
            roles: Set(ServerRole.allCases), required: false, enabled: false))
    }

    // MARK: Persistence

    private func save() {
        if let data = try? Self.encoder.encode(profile) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: Account sync

    func attach(_ account: AccountService) {
        self.account = account
    }

    private func scheduleSync() {
        guard let account, account.isSignedIn else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.pushNow()
        }
    }

    func pushNow() async {
        guard let account, account.isSignedIn else { return }
        do {
            switch try await account.push(profile) {
            case .accepted:
                account.status = "Synced \(Date().formatted(date: .omitted, time: .shortened))."
            case .conflict(let remote):
                adopt(remote)
                account.status = "Another device had newer changes, so they were loaded here."
            }
        } catch {
            account.status = "Sync failed: \(error.localizedDescription)"
        }
    }

    /// Pull the account's profile; newest edit wins. Call after sign-in, on launch and when the app returns to the foreground.
    func pullNow() async {
        guard let account, account.isSignedIn else { return }
        do {
            if let remote = try await account.pull() {
                if remote.updatedAt > profile.updatedAt {
                    adopt(remote)
                    account.status = "Loaded the latest settings from your account."
                } else if remote.updatedAt < profile.updatedAt {
                    await pushNow()
                } else {
                    account.status = "Everything is up to date."
                }
            } else {
                await pushNow()   // first time on this account
            }
        } catch {
            account.status = "Sync failed: \(error.localizedDescription)"
        }
    }

    private func adopt(_ remote: Profile) {
        internalChange = true
        profile = remote
        internalChange = false
        save()
        for host in remote.hosts where passwords[host.id] == nil {
            passwords[host.id] = Keychain.get("host-\(host.id.uuidString)") ?? ""
        }
    }
}
