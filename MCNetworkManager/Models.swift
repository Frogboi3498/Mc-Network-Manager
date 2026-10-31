import Foundation

// MARK: - Roles

enum ServerRole: String, Codable, CaseIterable, Identifiable, Hashable {
    case lobby, survival, creative

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .lobby: return "door.left.hand.open"
        case .survival: return "leaf"
        case .creative: return "paintbrush"
        }
    }
}

// MARK: - Profile pieces (everything here syncs to your account; no secrets)

struct Host: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Address this app uses for SSH (LAN IP, hostname, or Tailscale 100.x address).
    var sshAddress: String
    /// Address the proxy uses to reach this host's game servers. Blank = same as sshAddress.
    var backendAddress: String
    var username: String

    var effectiveBackend: String { backendAddress.isEmpty ? sshAddress : backendAddress }
}

struct ServerDef: Codable, Identifiable, Hashable {
    var id = UUID()
    var role: ServerRole
    var port: Int
    var memoryGB: Int
    var hostID: UUID

    var name: String { role.rawValue }
}

struct ModDef: Codable, Identifiable, Hashable {
    /// Modrinth project slug, or a unique id for custom jars.
    var id: String
    var title: String
    var summary: String
    var roles: Set<ServerRole>
    /// Required mods are needed for the network to work (Fabric API, proxy support).
    var required: Bool
    var enabled: Bool
    /// Direct .jar URL for custom mods. Empty for Modrinth mods.
    var customURL: String = ""

    var isCustom: Bool { id.hasPrefix("custom-") }
}

struct Profile: Codable, Equatable {
    var hosts: [Host]
    var servers: [ServerDef]
    var mods: [ModDef]
    var proxyHostID: UUID
    var proxyPort: Int = 25565
    var syncSurvivalToCreative: Bool = true
    /// Minecraft usernames, comma or space separated.
    var operators: String = ""
    var opRoles: Set<ServerRole> = [.lobby]
    var lobbyWorldURL: String = ""
    var installTailscale: Bool = false
    var autoPortForward: Bool = false
    var updatedAt: Date = Date()

    static func makeDefault() -> Profile {
        let host = Host(name: "Server 1", sshAddress: "", backendAddress: "", username: "")
        let servers = [
            ServerDef(role: .lobby, port: 25566, memoryGB: 2, hostID: host.id),
            ServerDef(role: .survival, port: 25567, memoryGB: 4, hostID: host.id),
            ServerDef(role: .creative, port: 25568, memoryGB: 3, hostID: host.id),
        ]
        let mods = [
            ModDef(id: "fabric-api", title: "Fabric API",
                   summary: "Library most Fabric mods depend on.",
                   roles: Set(ServerRole.allCases), required: true, enabled: true),
            ModDef(id: "fabricproxy-lite", title: "FabricProxy-Lite",
                   summary: "Lets the Velocity proxy forward players to Fabric servers.",
                   roles: Set(ServerRole.allCases), required: true, enabled: true),
            ModDef(id: "invview", title: "Inv View",
                   summary: "View other players' inventories (Survival and Creative).",
                   roles: [.survival, .creative], required: false, enabled: true),
            ModDef(id: "bluemap", title: "BlueMap",
                   summary: "Live web map showing players (Survival).",
                   roles: [.survival], required: false, enabled: true),
            ModDef(id: "custom-chunks", title: "Clear loaded chunks (your own jar)",
                   summary: "Paste a direct .jar download link for the chunk-clearing mod you use.",
                   roles: [.lobby], required: false, enabled: false),
        ]
        return Profile(hosts: [host], servers: servers, mods: mods, proxyHostID: host.id)
    }
}

// MARK: - Monitoring

struct ServerStat: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var state: String      // systemd state: active, inactive, failed, ...
    var players: Int?      // nil when the server did not answer a status ping
    var memoryMB: Int
}

struct HostStats: Hashable {
    var reachable: Bool
    var error: String?
    var load1: Double = 0
    var memUsedMB: Int = 0
    var memTotalMB: Int = 0
    var diskPercent: Int = 0
    var servers: [ServerStat] = []
    var updated: Date = Date()
}
