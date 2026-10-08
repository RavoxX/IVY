import CryptoKit
import Foundation
import IVYCore
import LocalAuthentication
import os

enum FaceIDVaultError: LocalizedError {
    case locked
    case keyLost
    case corrupted

    var errorDescription: String? {
        switch self {
        case .locked: return "Face ID data is locked. Authenticate with Touch ID or your password first."
        case .keyLost: return "The key for your Face ID data is missing. Reset Face ID to start over; nothing was deleted."
        case .corrupted: return "Your Face ID data couldn't be read. Reset Face ID to start over."
        }
    }
}

/// Encrypted storage for enrolled face templates and the Mac login password.
///
/// Everything lives in one AES-GCM file under a random 256-bit session key. That key is
/// wrapped by a Secure Enclave key that requires Touch ID or the account password to use,
/// so it is unwrapped once per launch (IVY can't show a prompt on the lock screen) and only
/// kept in memory. Macs without a Secure Enclave fall back to a Keychain item gated by the
/// same authentication prompt in IVY.
final class FaceIDVault: @unchecked Sendable {
    struct Contents: Codable, Equatable {
        var templates: [FaceTemplate] = []
        /// UTF-8 login password; empty when not stored.
        var password = Data()
    }

    private struct KeyFile: Codable {
        var enclaveKey: Data?
        var ephemeralPublicKey: Data?
        var wrappedKey: Data?
    }

    private static let keychainAccount = "faceid.sessionKey"
    private let directory: URL
    private var keyURL: URL { directory.appendingPathComponent("key.json") }
    private var vaultURL: URL { directory.appendingPathComponent("vault.enc") }
    private let lock = NSLock()
    private var sessionKey: SymmetricKey?

    init(directory: URL = AppPaths.applicationSupport.appendingPathComponent("FaceID", isDirectory: true)) {
        self.directory = directory
    }

    var isUnlocked: Bool { lock.withLock { sessionKey != nil } }
    var hasData: Bool { FileManager.default.fileExists(atPath: vaultURL.path) }

    /// Shows the system Touch ID / password prompt and unwraps (or creates) the session key.
    func unlock(reason: String) async throws {
        guard !isUnlocked else { return }
        let context = LAContext()
        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        let key = try loadOrCreateKey(context: context)
        lock.withLock { sessionKey = key }
        Log.faceID.info("Face ID vault unlocked")
    }

    func lockVault() {
        lock.withLock { sessionKey = nil }
    }

    func read() throws -> Contents {
        guard let key = lock.withLock({ sessionKey }) else { throw FaceIDVaultError.locked }
        guard let data = try? Data(contentsOf: vaultURL) else { return Contents() }
        guard let box = try? AES.GCM.SealedBox(combined: data), let plain = try? AES.GCM.open(box, using: key),
              let contents = try? JSONDecoder().decode(Contents.self, from: plain) else { throw FaceIDVaultError.corrupted }
        return contents
    }

    func write(_ contents: Contents) throws {
        guard let key = lock.withLock({ sessionKey }) else { throw FaceIDVaultError.locked }
        var plain = try JSONEncoder().encode(contents)
        defer { plain.resetBytes(in: 0..<plain.count) }
        guard let sealed = try AES.GCM.seal(plain, using: key).combined else { throw FaceIDVaultError.corrupted }
        try createDirectory()
        try sealed.write(to: vaultURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
    }

    /// Deletes all Face ID data: templates, the stored password and the keys.
    func reset() {
        lockVault()
        try? FileManager.default.removeItem(at: vaultURL)
        try? FileManager.default.removeItem(at: keyURL)
        Keychain.write("", account: Self.keychainAccount)
        Log.faceID.info("Face ID data deleted")
    }

    // MARK: - Keys

    private func loadOrCreateKey(context: LAContext) throws -> SymmetricKey {
        if let data = try? Data(contentsOf: keyURL), let file = try? JSONDecoder().decode(KeyFile.self, from: data) {
            return try unwrap(file, context: context)
        }
        if let stored = Keychain.read(account: Self.keychainAccount), let bytes = Data(base64Encoded: stored) {
            return SymmetricKey(data: bytes)
        }
        // Creating a new key would make existing data unreadable forever; refuse instead.
        guard !hasData else { throw FaceIDVaultError.keyLost }

        let key = SymmetricKey(size: .bits256)
        if SecureEnclave.isAvailable, let file = try? wrapInSecureEnclave(key, context: context) {
            try createDirectory()
            try JSONEncoder().encode(file).write(to: keyURL, options: .atomic)
            // Prove the round trip before relying on it.
            guard try unwrap(file, context: context) == key else { throw FaceIDVaultError.corrupted }
        } else {
            Log.faceID.info("Secure Enclave unavailable; storing the Face ID key in the Keychain")
            let status = Keychain.write(key.withUnsafeBytes { Data($0) }.base64EncodedString(), account: Self.keychainAccount)
            guard status == errSecSuccess else { throw FaceIDVaultError.corrupted }
        }
        return key
    }

    private func wrapInSecureEnclave(_ key: SymmetricKey, context: LAContext) throws -> KeyFile {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .userPresence], nil) else { throw FaceIDVaultError.corrupted }
        let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let wrapping = try Self.wrappingKey(ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey),
                                            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation)
        let wrapped = try AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: wrapping).combined
        return KeyFile(enclaveKey: enclaveKey.dataRepresentation,
                       ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
                       wrappedKey: wrapped)
    }

    private func unwrap(_ file: KeyFile, context: LAContext) throws -> SymmetricKey {
        guard let enclaveData = file.enclaveKey, let ephemeralData = file.ephemeralPublicKey, let wrapped = file.wrappedKey else {
            throw FaceIDVaultError.keyLost
        }
        let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: enclaveData, authenticationContext: context)
        let ephemeral = try P256.KeyAgreement.PublicKey(rawRepresentation: ephemeralData)
        let wrapping = try Self.wrappingKey(enclaveKey.sharedSecretFromKeyAgreement(with: ephemeral), ephemeralPublicKey: ephemeralData)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapped), using: wrapping)
        return SymmetricKey(data: plain)
    }

    private static func wrappingKey(_ secret: SharedSecret, ephemeralPublicKey: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("IVY Face ID".utf8),
                                       sharedInfo: ephemeralPublicKey, outputByteCount: 32)
    }

    private func createDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
