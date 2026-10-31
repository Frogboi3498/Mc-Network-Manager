import Foundation

// MARK: - Nodes

/// A machine (Linux, reachable over SSH) that will host part of the network.
struct NodeProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var password: String = ""

    var displayName: String { name.isEmpty ? host : name }
    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && (1...65535).contains(port)
    }
}

// MARK: - Network plan

enum GameMode: String, Codable, CaseIterable, Identifiable {
    case survival, creative, adventure, spectator
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum NetworkingMode: String, Codable, CaseIterable, Identifiable {
    case none, tailscale, upnp
    var id: String { rawValue }
}

struct ServerPlan: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var gameMode: GameMode
    var port: Int
    var memoryMB: Int
    var nodeID: UUID?
    /// Modrinth slugs of optional mods for this server. Nothing is installed
    /// until the person confirms the list on the consent screen.
    var optionalMods: [String] = []
}

struct NetworkPlan: Codable, Hashable {
    var name = "My Network"
    var proxyNodeID: UUID?
    var publicPort = 25565
    /// "latest" or a specific release such as "1.21.4".
    var minecraftVersion = "latest"
    var servers: [ServerPlan] = []
    var whitelist = true
    var operatorName = ""
    var operatorOnAllServers = true
    var networking: NetworkingMode = .none
    var tailscaleHostname = ""
    var syncSurvivalToCreative = false
    /// Shared secret between the proxy and the backends. Generated once.
    var forwardingSecret = ""
    var lastProvisioned: Date?

    /// The usual three-server layout: a lobby plus Survival and Creative.
    static func template() -> NetworkPlan {
        var plan = NetworkPlan()
        plan.forwardingSecret = SecretGenerator.alphanumeric(32)
        plan.servers = [
            ServerPlan(name: "lobby", gameMode: .adventure, port: 30066, memoryMB: 1024),
            ServerPlan(name: "survival", gameMode: .survival, port: 30067, memoryMB: 4096,
                       optionalMods: ModCatalog.suggestedMods(forServerNamed: "survival")),
            ServerPlan(name: "creative", gameMode: .creative, port: 30068, memoryMB: 2048,
                       optionalMods: ModCatalog.suggestedMods(forServerNamed: "creative")),
        ]
        return plan
    }
}

// MARK: - Vault (everything that syncs)

struct Vault: Codable, Equatable {
    var schema = 1
    var nodes: [NodeProfile] = []
    var plan = NetworkPlan.template()
    /// Modrinth slugs the person added themselves (beyond the built-in list).
    var customMods: [String] = []
    var updatedAt = Date()

    var isPristine: Bool { nodes.isEmpty && plan.lastProvisioned == nil }

    func node(_ id: UUID?) -> NodeProfile? {
        guard let id else { return nil }
        return nodes.first { $0.id == id }
    }
}

// Tolerant decoding: a vault written by an older or newer app version may be
// missing keys. Swift's synthesized decoder would reject it, so decode each
// field with a fallback instead.
extension NetworkPlan {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? name
        proxyNodeID = try c.decodeIfPresent(UUID.self, forKey: .proxyNodeID)
        publicPort = try c.decodeIfPresent(Int.self, forKey: .publicPort) ?? publicPort
        minecraftVersion = try c.decodeIfPresent(String.self, forKey: .minecraftVersion) ?? minecraftVersion
        servers = try c.decodeIfPresent([ServerPlan].self, forKey: .servers) ?? []
        whitelist = try c.decodeIfPresent(Bool.self, forKey: .whitelist) ?? whitelist
        operatorName = try c.decodeIfPresent(String.self, forKey: .operatorName) ?? ""
        operatorOnAllServers = try c.decodeIfPresent(Bool.self, forKey: .operatorOnAllServers) ?? true
        networking = try c.decodeIfPresent(NetworkingMode.self, forKey: .networking) ?? .none
        tailscaleHostname = try c.decodeIfPresent(String.self, forKey: .tailscaleHostname) ?? ""
        syncSurvivalToCreative = try c.decodeIfPresent(Bool.self, forKey: .syncSurvivalToCreative) ?? false
        forwardingSecret = try c.decodeIfPresent(String.self, forKey: .forwardingSecret) ?? ""
        lastProvisioned = try c.decodeIfPresent(Date.self, forKey: .lastProvisioned)
        if forwardingSecret.isEmpty { forwardingSecret = SecretGenerator.alphanumeric(32) }
    }
}

extension Vault {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        nodes = try c.decodeIfPresent([NodeProfile].self, forKey: .nodes) ?? []
        plan = try c.decodeIfPresent(NetworkPlan.self, forKey: .plan) ?? NetworkPlan.template()
        customMods = try c.decodeIfPresent([String].self, forKey: .customMods) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

// MARK: - Mods

struct ModInfo: Identifiable, Hashable {
    var id: String { slug }
    let slug: String
    let title: String
    let summary: String
    /// Server names this mod is suggested for in the default layout.
    let suggestedServers: Set<String>
}

struct RequiredMod: Identifiable, Hashable {
    var id: String { slug }
    let slug: String
    let title: String
    let why: String
}

enum ModCatalog {
    /// Mods carried over from the original network. Each one is opt-in.
    static let builtIn: [ModInfo] = [
        ModInfo(slug: "invview", title: "Inv View",
                summary: "Server-side Fabric mod from Modrinth.",
                suggestedServers: ["survival", "creative"]),
        ModInfo(slug: "bluemap", title: "BlueMap",
                summary: "Live web map of the world. Served on port 8100 of the node.",
                suggestedServers: ["survival"]),
    ]

    /// Always installed on every backend. Without these the proxy cannot
    /// forward players to the server, so they are disclosed but not optional.
    static let required: [RequiredMod] = [
        RequiredMod(slug: "fabric-api", title: "Fabric API", why: "Required by almost every Fabric mod."),
        RequiredMod(slug: "fabricproxy-lite", title: "FabricProxy-Lite", why: "Lets the Velocity proxy forward players to this server."),
    ]

    static func suggestedMods(forServerNamed name: String) -> [String] {
        builtIn.filter { $0.suggestedServers.contains(name) }.map(\.slug)
    }

    static func isValidSlug(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9_-]{2,64}$"#, options: .regularExpression) != nil
    }
}

// MARK: - Helpers

enum SecretGenerator {
    static func alphanumeric(_ length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count, using: &rng)] })
    }
}

extension JSONEncoder {
    static var vault: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var vault: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
