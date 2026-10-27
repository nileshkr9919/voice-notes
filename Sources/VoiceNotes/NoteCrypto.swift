import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Optional end-to-end encryption for the notes folder.
///
/// A passphrase is stretched into a 256-bit key with PBKDF2-SHA256; each note file is
/// sealed with AES-256-GCM. The folder holds a small `vault.vnkey` file (salt, iteration
/// count and a check value) so every Mac can tell the folder is encrypted and verify a
/// passphrase. The key itself never leaves this Mac's Keychain.
struct Vault: Codable, Equatable {
    var id: UUID
    var salt: Data
    var iterations: Int
    /// A known value sealed with the key, to tell a right passphrase from a wrong one.
    var check: Data

    static let fileName = "vault.vnkey"
    static let defaultIterations = 600_000
    private static let checkText = Data("voicenotes-vault-check".utf8)

    static func create(passphrase: String, iterations: Int = defaultIterations) throws -> (Vault, SymmetricKey) {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw NoteCryptoError.randomness }
        let key = try deriveKey(passphrase, salt: salt, iterations: iterations)
        let check = try NoteCrypto.seal(checkText, key: key)
        return (Vault(id: UUID(), salt: salt, iterations: iterations, check: check), key)
    }

    /// The key for `passphrase`, or nil if the passphrase is wrong.
    func key(for passphrase: String) -> SymmetricKey? {
        guard let key = try? Self.deriveKey(passphrase, salt: salt, iterations: iterations),
              let opened = try? NoteCrypto.open(check, key: key), opened == Self.checkText else { return nil }
        return key
    }

    func accepts(_ key: SymmetricKey) -> Bool {
        (try? NoteCrypto.open(check, key: key)) == Self.checkText
    }

    static func deriveKey(_ passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passphrase, passphrase.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                    out.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        guard status == kCCSuccess else { throw NoteCryptoError.keyDerivation }
        return SymmetricKey(data: derived)
    }
}

enum NoteCryptoError: LocalizedError {
    case randomness, keyDerivation, notEncrypted, locked, needsPassphrase, wrongPassphrase

    var errorDescription: String? {
        switch self {
        case .randomness, .keyDerivation: "Couldn't set up encryption on this Mac."
        case .notEncrypted: "This file isn't an encrypted note."
        case .locked: "Notes are locked. Enter the passphrase to unlock them."
        case .needsPassphrase: "That folder's notes are encrypted. Enter its passphrase."
        case .wrongPassphrase: "That passphrase isn't right."
        }
    }
}

enum NoteCrypto {
    /// Marks an encrypted note file (and its format version).
    private static let magic = Data("VN1".utf8)

    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw NoteCryptoError.keyDerivation }
        return magic + combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        guard data.starts(with: magic) else { throw NoteCryptoError.notEncrypted }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
        return try AES.GCM.open(box, using: key)
    }
}

/// Where this Mac keeps folder keys.
protocol KeyStore {
    func key(for vault: UUID) -> SymmetricKey?
    func save(_ key: SymmetricKey, for vault: UUID)
    func delete(for vault: UUID)
}

/// Keys live in the login Keychain; other apps can't read them without the person's approval.
struct KeychainKeyStore: KeyStore {
    private static let service = "VoiceNotes notes encryption"

    private func query(_ vault: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: vault.uuidString]
    }

    func key(for vault: UUID) -> SymmetricKey? {
        var q = query(vault)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    func save(_ key: SymmetricKey, for vault: UUID) {
        delete(for: vault)
        var q = query(vault)
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrLabel as String] = "Voice Notes encryption key"
        SecItemAdd(q as CFDictionary, nil)
    }

    func delete(for vault: UUID) {
        SecItemDelete(query(vault) as CFDictionary)
    }
}

/// In-memory keys, for tests.
final class MemoryKeyStore: KeyStore {
    private var keys: [UUID: SymmetricKey] = [:]
    func key(for vault: UUID) -> SymmetricKey? { keys[vault] }
    func save(_ key: SymmetricKey, for vault: UUID) { keys[vault] = key }
    func delete(for vault: UUID) { keys[vault] = nil }
}
