import Foundation
import Observation

/// One unit of work: run the provisioning script on one node.
struct ProvisionJob: Identifiable {
    let id = UUID()
    let node: NodeProfile
    let environment: [(String, String)]
    let summary: [String]
}

struct ProvisionOptions {
    var acceptedEULA = false
    var tailscaleAuthKey = ""
}

enum PlanValidator {
    static func isValidName(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9_-]{1,24}$"#, options: .regularExpression) != nil
    }

    static func isValidMinecraftVersion(_ s: String) -> Bool {
        s == "latest" || s.range(of: #"^[0-9]+(\.[0-9]+){1,3}$"#, options: .regularExpression) != nil
    }

    static func isValidPlayerName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9_]{3,16}$"#, options: .regularExpression) != nil
    }

    /// Human-readable problems that stop the plan from being installed.
    static func problems(in vault: Vault) -> [String] {
        let plan = vault.plan
        var out: [String] = []

        if vault.nodes.isEmpty { out.append("Add at least one node under Nodes.") }
        if plan.servers.isEmpty { out.append("Add at least one server.") }

        if plan.proxyNodeID == nil || vault.node(plan.proxyNodeID) == nil {
            out.append("Choose which node runs the proxy (the single join address).")
        }
        if !(1...65535).contains(plan.publicPort) { out.append("The public port must be between 1 and 65535.") }
        if !isValidMinecraftVersion(plan.minecraftVersion) { out.append("The Minecraft version must be \"latest\" or look like 1.21.4.") }
        if !plan.operatorName.isEmpty && !isValidPlayerName(plan.operatorName) {
            out.append("The operator name must be a valid Minecraft username (3 to 16 letters, numbers or underscores).")
        }

        var names = Set<String>()
        var portsByNode: [UUID: Set<Int>] = [:]
        if let proxy = plan.proxyNodeID { portsByNode[proxy, default: []].insert(plan.publicPort) }

        for server in plan.servers {
            if !isValidName(server.name) {
                out.append("Server name \"\(server.name)\" must be 1 to 24 characters: lowercase letters, numbers, dash or underscore.")
            }
            if !names.insert(server.name).inserted { out.append("Two servers are named \"\(server.name)\".") }
            if server.memoryMB < 512 { out.append("\(server.name): give it at least 512 MB of memory.") }
            if !(1...65535).contains(server.port) { out.append("\(server.name): the port must be between 1 and 65535.") }
            guard let nodeID = server.nodeID, let node = vault.node(nodeID) else {
                out.append("\(server.name): choose which node runs it."); continue
            }
            if !node.isComplete { out.append("\(node.displayName): fill in host, username and password.") }
            if !portsByNode[nodeID, default: []].insert(server.port).inserted {
                out.append("\(node.displayName): port \(server.port) is used twice.")
            }
            for slug in server.optionalMods where !ModCatalog.isValidSlug(slug) {
                out.append("\(server.name): \"\(slug)\" is not a valid mod name.")
            }
        }

        if let proxy = vault.node(plan.proxyNodeID), !proxy.isComplete {
            out.append("\(proxy.displayName): fill in host, username and password.")
        }
        if plan.syncSurvivalToCreative && syncPair(in: vault) == nil {
            out.append("Survival-to-Creative copying needs a Survival and a Creative server on the same node.")
        }
        // De-duplicate while keeping order.
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// The Survival and Creative servers that can be kept in sync (same node).
    static func syncPair(in vault: Vault) -> (source: ServerPlan, target: ServerPlan)? {
        let servers = vault.plan.servers
        for s in servers where s.gameMode == .survival {
            if let c = servers.first(where: { $0.gameMode == .creative && $0.nodeID == s.nodeID && $0.nodeID != nil }) {
                return (s, c)
            }
        }
        return nil
    }
}

enum Provisioner {
    /// Union of every optional mod slug in the plan, in a stable order.
    static func optionalMods(in vault: Vault) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in vault.plan.servers { for m in s.optionalMods where seen.insert(m).inserted { out.append(m) } }
        return out
    }

    /// Builds one job per node involved. Backend-only nodes come first and the
    /// proxy node last, so the join address only goes live once backends exist.
    static func jobs(for vault: Vault, options: ProvisionOptions) throws -> [ProvisionJob] {
        let problems = PlanValidator.problems(in: vault)
        if let first = problems.first { throw ProvisionError.invalid(first) }
        guard options.acceptedEULA else { throw ProvisionError.invalid("Accept the Minecraft EULA to continue.") }

        let plan = vault.plan
        guard let proxy = vault.node(plan.proxyNodeID) else { throw ProvisionError.invalid("No proxy node.") }

        var nodeIDs: [UUID] = []
        for s in plan.servers { if let id = s.nodeID, !nodeIDs.contains(id) { nodeIDs.append(id) } }
        if !nodeIDs.contains(proxy.id) { nodeIDs.append(proxy.id) }
        nodeIDs.removeAll { $0 == proxy.id }
        nodeIDs.append(proxy.id)

        let pair = plan.syncSurvivalToCreative ? PlanValidator.syncPair(in: vault) : nil

        let backends = plan.servers.compactMap { server -> String? in
            guard let node = vault.node(server.nodeID) else { return nil }
            let host = node.id == proxy.id ? "127.0.0.1" : node.host.trimmingCharacters(in: .whitespaces)
            return "\(server.name)|\(host)|\(server.port)"
        }.joined(separator: ";")

        return try nodeIDs.map { id in
            guard let node = vault.node(id) else { throw ProvisionError.invalid("Missing node.") }
            let isProxy = id == proxy.id
            let mine = plan.servers.filter { $0.nodeID == id }

            var env: [(String, String)] = [
                ("ACCEPT_EULA", "1"),
                ("MC_VERSION", plan.minecraftVersion),
                ("FORWARD_SECRET", plan.forwardingSecret),
                ("NETWORK_NAME", plan.name.isEmpty ? "Minecraft Network" : plan.name),
                ("PUBLIC_PORT", String(plan.publicPort)),
                ("WHITELIST", plan.whitelist ? "1" : "0"),
                ("OP_ALL", plan.operatorOnAllServers ? "1" : "0"),
                ("ROLE_PROXY", isProxy ? "1" : "0"),
            ]
            if !plan.operatorName.isEmpty { env.append(("OP_NAME", plan.operatorName)) }
            if !mine.isEmpty {
                env.append(("SERVERS", mine.map {
                    "\($0.name)|\($0.port)|\($0.gameMode.rawValue)|\($0.memoryMB)|\($0.optionalMods.joined(separator: ","))"
                }.joined(separator: ";")))
            }
            if isProxy {
                env.append(("BACKENDS", backends))
                env.append(("NET_MODE", plan.networking.rawValue))
                if plan.networking == .tailscale {
                    let host = plan.tailscaleHostname.trimmingCharacters(in: .whitespaces)
                    if !host.isEmpty { env.append(("TS_HOSTNAME", host)) }
                    if !options.tailscaleAuthKey.isEmpty { env.append(("TS_AUTHKEY", options.tailscaleAuthKey)) }
                }
            } else {
                env.append(("PROXY_HOST", proxy.host.trimmingCharacters(in: .whitespaces)))
            }
            if let pair, pair.source.nodeID == id {
                env.append(("SYNC_SRC", pair.source.name))
                env.append(("SYNC_DST", pair.target.name))
            }

            var summary: [String] = []
            if isProxy { summary.append("Velocity proxy on port \(plan.publicPort)") }
            for s in mine { summary.append("\(s.name) (\(s.gameMode.title), port \(s.port), \(s.memoryMB) MB)") }
            if isProxy, plan.networking != .none { summary.append(plan.networking == .tailscale ? "Tailscale" : "Automatic port forwarding (UPnP)") }
            if let pair, pair.source.nodeID == id { summary.append("Daily one-way copy: \(pair.source.name) to \(pair.target.name)") }
            return ProvisionJob(node: node, environment: env, summary: summary)
        }
    }

    /// The full command sent over SSH for a job.
    static func command(for job: ProvisionJob, script: String) -> String {
        let b64 = Data(script.utf8).base64EncodedString()
        let envArgs = job.environment.map { Shell.quote("\($0.0)=\($0.1)") }.joined(separator: " ")
        let run = Shell.privileged("env \(envArgs) bash \"$f\"", node: job.node)
        let program = """
        f=$(mktemp /tmp/mcnm.XXXXXX) || exit 1
        printf %s \(Shell.quote(b64)) | base64 -d > "$f"
        chmod 700 "$f"
        \(run) 2>&1
        rc=$?
        rm -f "$f"
        echo "MCNM_EXIT=$rc"
        """
        return Shell.bash(program)
    }

    static func loadScript() throws -> String {
        guard let url = Bundle.main.url(forResource: "provision", withExtension: "sh"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ProvisionError.invalid("The installer script is missing from the app bundle.")
        }
        return text
    }
}

enum ProvisionError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let m): return m }
    }
}

// MARK: - Running jobs

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let kind: Kind
    enum Kind { case info, warning, error, success, link }
}

@MainActor
@Observable
final class ProvisionRunner {
    enum Phase: Equatable { case idle, running(String), finished(success: Bool) }

    private(set) var phase: Phase = .idle
    private(set) var log: [LogLine] = []
    private(set) var joinAddresses: [String] = []
    private var task: Task<Void, Never>?

    var isRunning: Bool { if case .running = phase { return true } else { return false } }

    func start(vault: Vault, options: ProvisionOptions, onSuccess: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        log = []
        joinAddresses = []
        let jobs: [ProvisionJob]
        let script: String
        do {
            jobs = try Provisioner.jobs(for: vault, options: options)
            script = try Provisioner.loadScript()
        } catch {
            append("Cannot start: \(error.localizedDescription)", .error)
            phase = .finished(success: false)
            return
        }

        task = Task { [weak self] in
            var allOK = true
            for job in jobs {
                guard let self, !Task.isCancelled else { return }
                self.phase = .running(job.node.displayName)
                self.append("=== \(job.node.displayName) ===", .info)
                for item in job.summary { self.append("  \(item)", .info) }

                var exitCode: Int?
                do {
                    for try await line in SSHService.streamLines(job.node, Provisioner.command(for: job, script: script)) {
                        if let code = Self.exitCode(in: line) { exitCode = code; continue }
                        self.ingest(line)
                    }
                } catch {
                    self.append("Connection problem: \(error.localizedDescription)", .error)
                }
                if exitCode == 0 {
                    self.append("\(job.node.displayName): finished", .success)
                } else {
                    allOK = false
                    self.append("\(job.node.displayName): failed (exit \(exitCode.map(String.init) ?? "unknown")). Fix the problem above and run it again; the installer is safe to re-run.", .error)
                    break
                }
            }
            guard let self else { return }
            self.phase = .finished(success: allOK)
            if allOK { onSuccess() }
        }
    }

    /// Clears the log and returns to the review screen. Ignored while running.
    func reset() {
        guard !isRunning else { return }
        log = []
        joinAddresses = []
        phase = .idle
    }

    func cancel() {
        task?.cancel()
        phase = .finished(success: false)
        append("Cancelled. A node may be partway through; re-run to finish.", .warning)
    }

    nonisolated static func exitCode(in line: String) -> Int? {
        guard line.hasPrefix("MCNM_EXIT=") else { return nil }
        return Int(line.dropFirst("MCNM_EXIT=".count))
    }

    private func ingest(_ line: String) {
        if line.hasPrefix("MCNM_INFO ") {
            let kv = line.dropFirst("MCNM_INFO ".count)
            if kv.hasPrefix("join_address=") {
                joinAddresses.append(String(kv.dropFirst("join_address=".count)))
            }
            return
        }
        if line.contains("ERROR") { append(line, .error) }
        else if line.contains("WARN") { append(line, .warning) }
        else if line.contains("https://login.tailscale.com") { append(line, .link) }
        else { append(line, .info) }
    }

    private func append(_ text: String, _ kind: LogLine.Kind) {
        log.append(LogLine(text: text, kind: kind))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }
}
