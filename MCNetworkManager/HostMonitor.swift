import Foundation

/// Polls each host over SSH every few seconds: load, memory, disk, and each Minecraft service
/// (systemd state, players online via a local status ping, memory use).
@MainActor
final class HostMonitor: ObservableObject {
    @Published private(set) var stats: [UUID: HostStats] = [:]
    @Published private(set) var isRunning = false

    private var clients: [UUID: RemoteClient] = [:]
    private var loop: Task<Void, Never>?

    func start(store: AppStore) {
        guard loop == nil else { return }
        isRunning = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let profile = store.profile
                for host in profile.hosts {
                    if Task.isCancelled { break }
                    let servers = profile.servers.filter { $0.hostID == host.id }.map { ($0.name, $0.port) }
                        + (host.id == profile.proxyHostID ? [("proxy", profile.proxyPort)] : [])
                    let result = await self.poll(host: host, password: store.password(for: host), servers: servers)
                    self.stats[host.id] = result
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        isRunning = false
        let open = clients
        clients = [:]
        Task { for c in open.values { await c.close() } }
    }

    private func poll(host: Host, password: String, servers: [(String, Int)]) async -> HostStats {
        guard !host.sshAddress.isEmpty, !host.username.isEmpty else {
            return HostStats(reachable: false, error: "Enter this host's address and username on the Setup tab.")
        }
        guard !password.isEmpty else {
            return HostStats(reachable: false, error: "Enter this host's password on this device (Setup tab).")
        }
        do {
            let client: RemoteClient
            if let existing = clients[host.id] {
                client = existing
            } else {
                client = try await RemoteClient.connect(host: host.sshAddress, user: host.username, password: password)
                clients[host.id] = client
            }
            let script = Self.statsScript(servers: servers)
            let b64 = Data(script.utf8).base64EncodedString()
            let output = try await client.run("echo \(b64) | base64 -d | bash")
            return Self.parse(output)
        } catch {
            if let dead = clients.removeValue(forKey: host.id) { await dead.close() }
            return HostStats(reachable: false, error: error.localizedDescription)
        }
    }

    // MARK: Remote script + parser

    static func statsScript(servers: [(String, Int)]) -> String {
        let list = servers.map { "\($0.0):\($0.1)" }.joined(separator: " ")
        return #"""
slp() {
  ( exec 3<>/dev/tcp/127.0.0.1/"$1" 2>/dev/null || exit 1
    printf '\x13\x00\xff\xff\xff\xff\x0f\x09localhost\x00\x00\x01\x01\x00' >&3
    timeout 1 cat <&3 | grep -ao '"online":[0-9]*' | head -n1 | cut -d: -f2 ) 2>/dev/null
}
echo "LOAD $(cut -d' ' -f1 /proc/loadavg)"
free -m | awk '/^Mem:/{print "MEM " $3 " " $2}'
df -P / | awk 'NR==2{gsub("%","",$5); print "DISK " $5}'
"""# + "\nfor s in \(list); do\n" + #"""
  n=${s%%:*}; p=${s##*:}
  a=$(systemctl is-active "minecraft-$n" 2>/dev/null || true)
  pl=""
  if [ "$a" = active ]; then pl=$(slp "$p" || true); fi
  pid=$(systemctl show -p MainPID --value "minecraft-$n" 2>/dev/null || echo 0)
  rss=0
  if [ -n "$pid" ] && [ "$pid" != 0 ]; then rss=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$pid/status" 2>/dev/null || echo 0); fi
  echo "SRV $n ${a:-unknown} ${pl:--1} ${rss:-0}"
done
"""#
    }

    static func parse(_ text: String) -> HostStats {
        var s = HostStats(reachable: true)
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            guard let tag = f.first else { continue }
            switch tag {
            case "LOAD" where f.count >= 2: s.load1 = Double(f[1]) ?? 0
            case "MEM" where f.count >= 3: s.memUsedMB = Int(f[1]) ?? 0; s.memTotalMB = Int(f[2]) ?? 0
            case "DISK" where f.count >= 2: s.diskPercent = Int(f[1]) ?? 0
            case "SRV" where f.count >= 5:
                let players = Int(f[3]) ?? -1
                s.servers.append(ServerStat(name: f[1], state: f[2], players: players >= 0 ? players : nil, memoryMB: Int(f[4]) ?? 0))
            default: break
            }
        }
        return s
    }
}
