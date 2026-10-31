import Foundation
import CryptoKit
import Observation

/// What is remembered about a signed-in account. Lives in the Keychain.
struct AccountSession: Codable, Equatable {
    var serverURL: String
    var username: String
    var token: String
    var encryptionKey: Data
    /// Server revision this device last synced with.
    var revision: Int
}

enum SyncState: Equatable {
    case localOnly
    case idle(lastSync: Date?)
    case syncing
    case failed(String)
}

/// Pending decision when signing in on a device that already has its own data.
struct SyncChoice: Identifiable {
    let id = UUID()
    let remote: Vault
    let remoteRevision: Int
}

@MainActor
@Observable
final class AppModel {
    var vault: Vault
    private(set) var session: AccountSession?
    private(set) var syncState: SyncState = .localOnly
    var syncChoice: SyncChoice?
    var lastError: String?

    private var dirty = false
    private var pushTask: Task<Void, Never>?
    private let fileURL: URL

    // MARK: Launch

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MCNetworkManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("vault.bin")

        vault = Vault()
        if let data = Keychain.get("session"), let s = try? JSONDecoder().decode(AccountSession.self, from: data) {
            session = s
            syncState = .idle(lastSync: nil)
        }
        if let loaded = loadLocal() { vault = loaded }
        if session != nil { Task { await pull() } }
    }

    // MARK: Local persistence (always encrypted at rest)

    private var localKey: SymmetricKey {
        if let session { return SymmetricKey(data: session.encryptionKey) }
        if let raw = Keychain.get("localKey") { return SymmetricKey(data: raw) }
        let key = VaultCrypto.randomKey()
        Keychain.set(key.rawData, for: "localKey")
        return key
    }

    private func loadLocal() -> Vault? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? VaultCrypto.decrypt(data, key: localKey)
    }

    private func saveLocal() {
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        do {
            let data = try VaultCrypto.encrypt(vault, key: localKey)
            try data.write(to: fileURL, options: options)
        } catch {
            lastError = "Could not save your settings: \(error.localizedDescription)"
        }
    }

    /// Call after every change the person makes.
    func commit() {
        vault.updatedAt = Date()
        saveLocal()
        dirty = true
        schedulePush()
    }

    // MARK: Account

    func register(serverURL: String, username: String, password: String, inviteCode: String) async -> Bool {
        guard let client = SyncClient(serverURL: serverURL) else { lastError = "Enter a valid server address."; return false }
        guard password.count >= 8 else { lastError = "Use a password of at least 8 characters."; return false }
        syncState = .syncing
        do {
            let salt = VaultCrypto.randomSalt()
            let keys = try await VaultCrypto.deriveKeys(password: password, salt: salt)
            let token = try await client.register(username: username, kdfSalt: salt, authKey: keys.authKey, inviteCode: inviteCode)
            setSession(AccountSession(serverURL: serverURL, username: username.lowercased(), token: token,
                                      encryptionKey: keys.encryption.rawData, revision: 0))
            dirty = true
            await push()
            return true
        } catch {
            syncState = .localOnly
            lastError = error.localizedDescription
            return false
        }
    }

    func login(serverURL: String, username: String, password: String) async -> Bool {
        guard let client = SyncClient(serverURL: serverURL) else { lastError = "Enter a valid server address."; return false }
        syncState = .syncing
        do {
            let (salt, iterations) = try await client.salt(for: username)
            guard iterations >= 100_000 else { throw SyncError(message: "The server asked for weak key stretching. Refusing to sign in.") }
            let keys = try await VaultCrypto.deriveKeys(password: password, salt: salt, iterations: iterations)
            let token = try await client.login(username: username, authKey: keys.authKey)
            var authed = client
            authed.token = token

            let remote = try await authed.getVault()
            let newSession = AccountSession(serverURL: serverURL, username: username.lowercased(), token: token,
                                            encryptionKey: keys.encryption.rawData, revision: remote?.revision ?? 0)
            guard let remote, let blob = remote.data else {
                // Nothing in the cloud yet: upload what this device has.
                setSession(newSession)
                dirty = true
                await push()
                return true
            }
            let remoteVault = try VaultCrypto.decrypt(blob, key: keys.encryption)
            if vault.isPristine {
                setSession(newSession)
                vault = remoteVault
                saveLocal()
                dirty = false
                syncState = .idle(lastSync: Date())
            } else {
                // Both sides have data: let the person choose.
                setSession(newSession)
                syncChoice = SyncChoice(remote: remoteVault, remoteRevision: remote.revision)
                syncState = .idle(lastSync: nil)
            }
            return true
        } catch {
            syncState = session == nil ? .localOnly : .idle(lastSync: nil)
            lastError = error.localizedDescription
            return false
        }
    }

    func resolve(useCloud: Bool) async {
        guard let choice = syncChoice else { return }
        syncChoice = nil
        if useCloud {
            vault = choice.remote
            saveLocal()
            dirty = false
            session?.revision = choice.remoteRevision
            persistSession()
            syncState = .idle(lastSync: Date())
        } else {
            session?.revision = choice.remoteRevision
            persistSession()
            saveLocal()
            dirty = true
            await push()
        }
    }

    func logout() async {
        guard let session else { return }
        if let client = SyncClient(serverURL: session.serverURL, token: session.token) { await client.logout() }
        // Keep working locally: re-encrypt the data under a fresh local-only key.
        let current = vault
        Keychain.delete("session")
        Keychain.delete("localKey")
        self.session = nil
        vault = current
        saveLocal()
        syncState = .localOnly
    }

    func deleteAccount(password: String) async -> Bool {
        guard let session, let client = SyncClient(serverURL: session.serverURL, token: session.token) else { return false }
        do {
            let (salt, iterations) = try await client.salt(for: session.username)
            let keys = try await VaultCrypto.deriveKeys(password: password, salt: salt, iterations: iterations)
            try await client.deleteAccount(authKey: keys.authKey)
            await logout()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Sync

    func syncNow() async {
        guard session != nil else { return }
        await pull()
        if dirty { await push() }
    }

    private func schedulePush() {
        guard session != nil else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    private func pull() async {
        guard let s = session, let client = SyncClient(serverURL: s.serverURL, token: s.token) else { return }
        syncState = .syncing
        do {
            guard let remote = try await client.getVault(), let blob = remote.data else {
                syncState = .idle(lastSync: Date()); return
            }
            if remote.revision > (session?.revision ?? s.revision) {
                let remoteVault = try VaultCrypto.decrypt(blob, key: SymmetricKey(data: s.encryptionKey))
                vault = dirty ? Self.merge(local: vault, remote: remoteVault) : remoteVault
                saveLocal()
                session?.revision = remote.revision
                persistSession()
            }
            syncState = .idle(lastSync: Date())
        } catch {
            handleSyncError(error)
        }
    }

    private func push() async {
        guard let s = session, let client = SyncClient(serverURL: s.serverURL, token: s.token) else { return }
        syncState = .syncing
        let key = SymmetricKey(data: s.encryptionKey)
        do {
            for _ in 0..<2 {   // second pass resolves one conflict
                let blob = try VaultCrypto.encrypt(vault, key: key)
                switch try await client.putVault(baseRevision: session?.revision ?? s.revision, blob: blob) {
                case .saved(let revision):
                    session?.revision = revision
                    persistSession()
                    dirty = false
                    syncState = .idle(lastSync: Date())
                    return
                case .conflict(let remote):
                    guard let remoteBlob = remote.data else { throw SyncError(message: "The server sent unreadable data.") }
                    let remoteVault = try VaultCrypto.decrypt(remoteBlob, key: key)
                    vault = Self.merge(local: vault, remote: remoteVault)
                    saveLocal()
                    session?.revision = remote.revision
                    persistSession()
                }
            }
            throw SyncError(message: "Another device changed your data at the same time. Try again.")
        } catch {
            handleSyncError(error)
        }
    }

    private func handleSyncError(_ error: Error) {
        let msg = error.localizedDescription
        if (error as? SyncError)?.code == "unauthorized" {
            // The token expired or was revoked. Keep the data, drop the account link.
            let current = vault
            Keychain.delete("session")
            session = nil
            vault = current
            saveLocal()
            syncState = .localOnly
            lastError = msg
        } else {
            syncState = .failed(msg)
        }
    }

    /// Merge two copies after a conflict. Items are matched by id; for items
    /// on both sides the copy from the more recently edited vault wins, and
    /// items that exist on only one side are kept.
    nonisolated static func merge(local: Vault, remote: Vault) -> Vault {
        let newer = local.updatedAt >= remote.updatedAt ? local : remote
        let older = local.updatedAt >= remote.updatedAt ? remote : local
        var result = newer
        let ids = Set(newer.nodes.map(\.id))
        result.nodes += older.nodes.filter { !ids.contains($0.id) }
        result.customMods = Array(Set(newer.customMods).union(older.customMods)).sorted()
        result.updatedAt = max(local.updatedAt, remote.updatedAt)
        return result
    }

    // MARK: Session storage

    private func setSession(_ s: AccountSession) {
        let current = vault
        session = s
        persistSession()
        Keychain.delete("localKey")
        vault = current
        saveLocal()   // re-encrypt local data under the account key
    }

    private func persistSession() {
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        Keychain.set(data, for: "session")
    }
}
