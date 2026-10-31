import Foundation

/// Talks to your own sync server (see SyncServer/). Handles account creation, sign-in and profile sync.
@MainActor
final class AccountService: ObservableObject {
    struct APIError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    enum PushResult {
        case accepted
        case conflict(Profile)
    }

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "syncServerURL") }
    }
    @Published private(set) var email: String?
    @Published private(set) var isSignedIn: Bool
    @Published var status: String = ""

    private var token: String?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    init() {
        serverURL = UserDefaults.standard.string(forKey: "syncServerURL") ?? ""
        email = UserDefaults.standard.string(forKey: "syncEmail")
        token = Keychain.get("sync-token")
        isSignedIn = token != nil
    }

    // MARK: Account

    func register(email: String, password: String) async throws {
        try await authenticate(path: "api/register", email: email, password: password)
    }

    func login(email: String, password: String) async throws {
        try await authenticate(path: "api/login", email: email, password: password)
    }

    func logout() {
        token = nil
        email = nil
        isSignedIn = false
        status = "Signed out."
        Keychain.remove("sync-token")
        UserDefaults.standard.removeObject(forKey: "syncEmail")
    }

    private func authenticate(path: String, email: String, password: String) async throws {
        let cleaned = email.trimmingCharacters(in: .whitespaces).lowercased()
        let body = try JSONSerialization.data(withJSONObject: ["email": cleaned, "password": password])
        let (data, code) = try await send(path, method: "POST", body: body, authorised: false)
        guard code == 200 || code == 201 else { throw APIError(Self.errorText(data, code)) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = obj["token"] as? String else { throw APIError("Unexpected reply from the sync server.") }
        token = tok
        self.email = cleaned
        isSignedIn = true
        Keychain.set(tok, for: "sync-token")
        UserDefaults.standard.set(cleaned, forKey: "syncEmail")
        status = "Signed in as \(cleaned)."
    }

    // MARK: Profile sync

    /// Returns nil when the account has no saved profile yet.
    func pull() async throws -> Profile? {
        let (data, code) = try await send("api/profile", method: "GET", body: nil, authorised: true)
        if code == 404 { return nil }
        guard code == 200 else { throw APIError(Self.errorText(data, code)) }
        return try Self.decodeProfile(from: data)
    }

    func push(_ profile: Profile) async throws -> PushResult {
        let envelope = Envelope(updatedAt: profile.updatedAt.timeIntervalSince1970, profile: profile)
        let body = try Self.encoder.encode(envelope)
        let (data, code) = try await send("api/profile", method: "PUT", body: body, authorised: true)
        switch code {
        case 200: return .accepted
        case 409: return .conflict(try Self.decodeProfile(from: data))
        default: throw APIError(Self.errorText(data, code))
        }
    }

    private struct Envelope: Codable {
        var updatedAt: Double
        var profile: Profile
    }

    private static func decodeProfile(from data: Data) throws -> Profile {
        try decoder.decode(Envelope.self, from: data).profile
    }

    // MARK: HTTP

    private func send(_ path: String, method: String, body: Data?, authorised: Bool) async throws -> (Data, Int) {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmed), let scheme = base.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw APIError("Enter your sync server address first, for example https://myserver.tailnet-name.ts.net")
        }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 15
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorised {
            guard let token else { throw APIError("You are not signed in.") }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && authorised {
            logout()
            throw APIError("Your session expired. Please sign in again.")
        }
        return (data, code)
    }

    private static func errorText(_ data: Data, _ code: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["error"] as? String { return msg }
        return "The sync server answered with status \(code)."
    }
}
