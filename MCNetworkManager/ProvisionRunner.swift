import Foundation

/// Runs the provisioning script on each host (backends first, proxy host last) and collects the log.
@MainActor
final class ProvisionRunner: ObservableObject {
    @Published private(set) var log = ""
    @Published private(set) var running = false
    @Published private(set) var finished = false
    @Published private(set) var succeeded = false
    @Published private(set) var tailscaleLoginURL: URL?
    @Published private(set) var currentHost = ""

    private var task: Task<Void, Never>?

    func problems(in store: AppStore) -> [String] {
        var list: [String] = []
        let p = store.profile
        if !store.eulaAccepted { list.append("Accept the Minecraft EULA on the Setup tab.") }
        if !store.modsAccepted { list.append("Review and accept the mod list on the Mods tab.") }
        for host in p.hosts {
            if host.sshAddress.trimmingCharacters(in: .whitespaces).isEmpty { list.append("\(host.name): enter an SSH address.") }
            if host.username.trimmingCharacters(in: .whitespaces).isEmpty { list.append("\(host.name): enter a username.") }
            if store.password(for: host).isEmpty { list.append("\(host.name): enter the password on this device.") }
        }
        let ports = p.servers.map(\.port) + [p.proxyPort]
        if Set(ports).count != ports.count {
            // Same port on different hosts is fine; only flag clashes on the same host.
            var seen = Set<String>()
            for s in p.servers {
                let key = "\(s.hostID)-\(s.port)"
                if !seen.insert(key).inserted { list.append("Two servers on the same host use port \(s.port).") }
            }
        }
        return list
    }

    func start(store: AppStore) {
        guard !running else { return }
        let profile = store.profile
        let hosts = profile.hosts.sorted { a, _ in a.id != profile.proxyHostID }   // proxy host last
        let passwords = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, store.password(for: $0)) })
        let tsKey = store.tailscaleAuthKey
        let secret = Self.randomSecret()

        log = ""
        finished = false
        succeeded = false
        tailscaleLoginURL = nil
        running = true

        task = Task { [weak self] in
            guard let self else { return }
            var allOK = true
            for host in hosts {
                if Task.isCancelled { allOK = false; break }
                self.currentHost = host.name
                self.append("\n######## \(host.name) (\(host.sshAddress)) ########\n")
                do {
                    let client = try await RemoteClient.connect(
                        host: host.sshAddress.trimmingCharacters(in: .whitespaces),
                        user: host.username, password: passwords[host.id] ?? "")
                    let script = ProvisionScript.make(for: host, profile: profile, secret: secret, tailscaleAuthKey: tsKey)
                    let command = ProvisionScript.remoteCommand(script: script, user: host.username, password: passwords[host.id] ?? "")
                    // stream() throws if the script exits non-zero, so reaching the next line means success.
                    try await client.stream(command) { [weak self] text in
                        Task { @MainActor in self?.append(text) }
                    }
                    await client.close()
                } catch {
                    allOK = false
                    self.append("\n!! \(host.name) failed: \(error.localizedDescription)\n")
                    break
                }
            }
            self.running = false
            self.finished = true
            self.succeeded = allOK
            self.append(allOK ? "\nAll hosts finished.\n" : "\nStopped because of an error. Fix it and run again; the script is safe to repeat.\n")
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func append(_ text: String) {
        log += text
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
        if tailscaleLoginURL == nil,
           let range = log.range(of: #"https://login\.tailscale\.com/[A-Za-z0-9/_\-]+"#, options: .regularExpression) {
            tailscaleLoginURL = URL(string: String(log[range]))
        }
    }

    private static func randomSecret() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in chars.randomElement(using: &rng)! })
    }
}
