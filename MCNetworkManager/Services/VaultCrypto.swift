import Foundation
import CryptoKit
import CommonCrypto

/// Client-side encryption for the synced vault.
///
/// The account password is stretched with PBKDF2-HMAC-SHA256 into 64 bytes.
/// The first 32 become the vault encryption key and never leave the device.
/// The last 32 are sent to the sync server as the login proof, so the server
/// never sees the password or the key that can read your data.
enum VaultCrypto {
    static let iterations: UInt32 = 600_000

    struct Keys {
        let encryption: SymmetricKey
        /// Hex string sent to the server to prove knowledge of the password.
        let authKey: String
    }

    enum CryptoError: LocalizedError {
        case derivationFailed
        case badCiphertext
        var errorDescription: String? {
            switch self {
            case .derivationFailed: return "Could not derive encryption keys."
            case .badCiphertext: return "The stored data could not be decrypted."
            }
        }
    }

    static func randomSalt(_ count: Int = 16) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// Runs the slow key derivation off the calling thread.
    static func deriveKeys(password: String, salt: Data, iterations: UInt32 = VaultCrypto.iterations) async throws -> Keys {
        try await Task.detached(priority: .userInitiated) {
            try deriveKeysSync(password: password, salt: salt, iterations: iterations)
        }.value
    }

    static func deriveKeysSync(password: String, salt: Data, iterations: UInt32) throws -> Keys {
        var derived = [UInt8](repeating: 0, count: 64)
        let saltBytes = [UInt8](salt)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.utf8.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            iterations,
            &derived, derived.count
        )
        guard status == Int32(kCCSuccess) else { throw CryptoError.derivationFailed }
        let enc = SymmetricKey(data: Data(derived[0..<32]))
        let auth = derived[32..<64].map { String(format: "%02x", $0) }.joined()
        return Keys(encryption: enc, authKey: auth)
    }

    static func randomKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw CryptoError.badCiphertext }
        return combined
    }

    static func open(_ ciphertext: Data, key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw CryptoError.badCiphertext
        }
    }

    static func encrypt(_ vault: Vault, key: SymmetricKey) throws -> Data {
        try seal(try JSONEncoder.vault.encode(vault), key: key)
    }

    static func decrypt(_ data: Data, key: SymmetricKey) throws -> Vault {
        try JSONDecoder.vault.decode(Vault.self, from: try open(data, key: key))
    }
}

extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}
