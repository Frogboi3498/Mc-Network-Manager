import Foundation

struct SyncError: LocalizedError {
    let message: String
    /// Machine-readable code from the server, when there is one.
    var code: String? = nil
    var errorDescription: String? { message }
}

struct RemoteVault: Decodable {
    let revision: Int
    let blob: String   // base64 of the encrypted vault
    let updatedAt: String?

    var data: Data? { Data(base64Encoded: blob) }
}

enum PutResult {
    case saved(revision: Int)
    case conflict(RemoteVault)
}

/// Talks to the self-hosted sync server (see SyncServer/).
struct SyncClient {
    let baseURL: URL
    var token: String?

    init?(serverURL: String, token: String? = nil) {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        self.baseURL = url
        self.token = token
    }

    /// A caution to show when the address is unencrypted and not on a private network.
    static func transportWarning(for serverURL: String) -> String? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s), url.scheme == "http", let host = url.host else { return nil }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") || !host.contains(".") { return nil }
        let p = host.split(separator: ".").compactMap { Int($0) }
        if p.count == 4 {
            if p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) { return nil }
            if p[0] == 172 && (16...31).contains(p[1]) { return nil }
            if p[0] == 100 && (64...127).contains(p[1]) { return nil }   // Tailscale / CGNAT range
        }
        return "This address is not encrypted. Your data is encrypted before upload, but use https:// when the server is on the internet."
    }

    // MARK: Account

    func salt(for username: String) async throws -> (salt: Data, iterations: UInt32) {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/salt"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "username", value: username.lowercased())]
        let (data, _) = try await send(URLRequest(url: comps.url!), expecting: [200])
        struct R: Decodable { let kdfSalt: String; let iterations: UInt32? }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard let salt = Data(base64Encoded: r.kdfSalt) else { throw SyncError(message: "The server sent an invalid salt.") }
        return (salt, r.iterations ?? VaultCrypto.iterations)
    }

    func register(username: String, kdfSalt: Data, authKey: String, inviteCode: String?) async throws -> String {
        var body: [String: Any] = [
            "username": username.lowercased(),
            "kdfSalt": kdfSalt.base64EncodedString(),
            "authKey": authKey,
        ]
        if let inviteCode, !inviteCode.isEmpty { body["inviteCode"] = inviteCode }
        return try await tokenRequest("api/register", body: body, success: 201)
    }

    func login(username: String, authKey: String) async throws -> String {
        try await tokenRequest("api/login", body: ["username": username.lowercased(), "authKey": authKey], success: 200)
    }

    func logout() async {
        var req = request("api/logout", method: "POST")
        req.httpBody = nil
        _ = try? await send(req, expecting: [204])
    }

    func deleteAccount(authKey: String) async throws {
        var req = request("api/account", method: "DELETE")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["authKey": authKey])
        _ = try await send(req, expecting: [204])
    }

    // MARK: Vault

    func getVault() async throws -> RemoteVault? {
        let (data, status) = try await send(request("api/vault", method: "GET"), expecting: [200, 404])
        if status == 404 { return nil }
        return try JSONDecoder().decode(RemoteVault.self, from: data)
    }

    func putVault(baseRevision: Int, blob: Data) async throws -> PutResult {
        var req = request("api/vault", method: "PUT")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "baseRevision": baseRevision,
            "blob": blob.base64EncodedString(),
        ])
        let (data, status) = try await send(req, expecting: [200, 409])
        if status == 409 {
            return .conflict(try JSONDecoder().decode(RemoteVault.self, from: data))
        }
        struct R: Decodable { let revision: Int }
        return .saved(revision: try JSONDecoder().decode(R.self, from: data).revision)
    }

    // MARK: Plumbing

    private func tokenRequest(_ path: String, body: [String: Any], success: Int) async throws -> String {
        var req = request(path, method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await send(req, expecting: [success])
        struct R: Decodable { let token: String }
        return try JSONDecoder().decode(R.self, from: data).token
    }

    private func request(_ path: String, method: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func send(_ req: URLRequest, expecting ok: [Int]) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw SyncError(message: "Could not reach the sync server (\(error.localizedDescription)).")
        }
        guard let http = response as? HTTPURLResponse else { throw SyncError(message: "Unexpected response from the server.") }
        if ok.contains(http.statusCode) { return (data, http.statusCode) }

        struct E: Decodable { let error: String }
        let code = (try? JSONDecoder().decode(E.self, from: data))?.error ?? "HTTP \(http.statusCode)"
        throw SyncError(message: Self.friendly(code), code: code)
    }

    private static func friendly(_ code: String) -> String {
        switch code {
        case "username_taken": return "That username is already taken."
        case "invalid_credentials": return "Wrong username or password."
        case "too_many_attempts": return "Too many failed attempts. Try again in 15 minutes."
        case "registration_disabled": return "This server is not accepting new accounts."
        case "bad_invite_code": return "The invite code is wrong."
        case "bad_username": return "Usernames are 3 to 32 characters: letters, numbers, dot, dash or underscore."
        case "unauthorized": return "You have been signed out. Sign in again."
        default: return "The server reported an error (\(code))."
        }
    }
}
