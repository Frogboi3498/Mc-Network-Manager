import Foundation
import Observation

struct ServiceState: Identifiable, Equatable {
    var id: String { name }
    let name: String      // "proxy" or a server name
    let state: String     // systemd state: active, inactive, failed...
    var isActive: Bool { state == "active" }
}

struct NodeSnapshot: Equatable {
    var load = ""
    var memory = ""       // "used/total" in MB
    var disk = ""
    var uptime = ""
    var tailscaleIP = ""
    var services: [ServiceState] = []
    var error: String?
    var updatedAt = Date()

    var memoryPercent: Double? {
        let parts = memory.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }
}

enum ServiceAction: String, CaseIterable, Identifiable {
    case start, stop, restart
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum Monitor {
    /// Shell program that prints KEY=VALUE lines describing the node.
    static let metricsProgram = #"""
    echo "LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
    echo "MEM=$(free -m 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}')"
    echo "DISK=$(df -P / 2>/dev/null | awk 'NR==2 {print $5}')"
    echo "UPTIME=$(uptime -p 2>/dev/null)"
    echo "TS=$(tailscale ip -4 2>/dev/null | head -n1)"
    if [ -d /opt/mcnm/proxy ]; then echo "SVC:proxy=$(systemctl is-active mcnm-proxy.service 2>/dev/null)"; fi
    for d in /opt/mcnm/servers/*/; do
      [ -d "$d" ] || continue
      n=$(basename "$d")
      echo "SVC:$n=$(systemctl is-active "mcnm@$n.service" 2>/dev/null)"
    done
    """#

    static func parse(_ output: String) -> NodeSnapshot {
        var snap = NodeSnapshot()
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "LOAD": snap.load = value
            case "MEM": snap.memory = value
            case "DISK": snap.disk = value
            case "UPTIME": snap.uptime = value.replacingOccurrences(of: "up ", with: "")
            case "TS": snap.tailscaleIP = value
            default:
                if key.hasPrefix("SVC:") {
                    snap.services.append(ServiceState(name: String(key.dropFirst(4)), state: value.isEmpty ? "unknown" : value))
                }
            }
        }
        return snap
    }

    static func unitName(for service: String) -> String? {
        guard PlanValidator.isValidName(service) || service == "proxy" else { return nil }
        return service == "proxy" ? "mcnm-proxy.service" : "mcnm@\(service).service"
    }
}

@MainActor
@Observable
final class MonitorModel {
    private(set) var snapshots: [UUID: NodeSnapshot] = [:]
    private(set) var players: [String: Result<MinecraftStatus, PingError>] = [:]
    private(set) var isRefreshing = false
    var banner: String?

    nonisolated static func pingKey(host: String, port: Int) -> String { "\(host):\(port)" }

    func refresh(vault: Vault) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let nodes = vault.nodes.filter(\.isComplete)
        await withTaskGroup(of: (UUID, NodeSnapshot).self) { group in
            for node in nodes {
                group.addTask {
                    do {
                        let out = try await SSHService.run(node, Shell.bash(Monitor.metricsProgram))
                        return (node.id, Monitor.parse(out))
                    } catch {
                        var snap = NodeSnapshot()
                        snap.error = error.localizedDescription
                        return (node.id, snap)
                    }
                }
            }
            for await (id, snap) in group { snapshots[id] = snap }
        }

        // Live player counts, best effort.
        var targets: [(String, Int)] = []
        if let proxy = vault.node(vault.plan.proxyNodeID) { targets.append((proxy.host, vault.plan.publicPort)) }
        for s in vault.plan.servers { if let n = vault.node(s.nodeID) { targets.append((n.host, s.port)) } }
        await withTaskGroup(of: (String, Result<MinecraftStatus, PingError>).self) { group in
            for (host, port) in targets {
                group.addTask {
                    do { return (Self.pingKey(host: host, port: port), .success(try await MinecraftPing.ping(host: host, port: port))) }
                    catch { return (Self.pingKey(host: host, port: port), .failure((error as? PingError) ?? .closed)) }
                }
            }
            for await (key, result) in group { players[key] = result }
        }
    }

    /// Starts, stops or restarts one service. Returns an error message on failure.
    func control(_ action: ServiceAction, service: String, on node: NodeProfile) async -> String? {
        guard let unit = Monitor.unitName(for: service) else { return "Unknown service." }
        let command = Shell.bash(Shell.privileged("systemctl \(action.rawValue) \(unit)", node: node))
        do {
            _ = try await SSHService.run(node, command, timeout: 60)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
