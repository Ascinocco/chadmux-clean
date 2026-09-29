import Foundation
import Security
import Crypto
import NIO
import NIOSSH

struct MacConnection: Codable, Equatable {
    var host = ""
    var port = 22
    var username = ""
    var isValid: Bool {
        !host.isEmpty && !username.isEmpty && (1...65535).contains(port) &&
        !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) &&
        !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    var apiTokenID: String { "transcription-token:" + trustID }
    var trustID: String { "host:\(host.lowercased()):\(port)" }
}

struct SecretStore {
    var service = "com.ascinocco.chadmux"
    /// On macOS, the data-protection keychain (as on iOS) rather than the legacy
    /// file keychain, so accessibility classes apply. It needs the signed app's
    /// keychain access group.
    private func base(_ account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
    func read(_ account: String) throws -> Data? {
        let query: [String: Any] = base(account).merging([kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
        var value: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = value as? Data else { throw StorageError(status: result) }
        return data
    }
    func write(_ data: Data, account: String) throws {
        let query = base(account)
        let changes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if result == errSecItemNotFound {
            let added = SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw StorageError(status: added) }
        } else if result != errSecSuccess { throw StorageError(status: result) }
    }
    func remove(_ account: String) throws {
        let query = base(account)
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw StorageError(status: result) }
    }
    func deviceKey() throws -> Curve25519.Signing.PrivateKey {
        if let data = try read("device-ed25519") { return try .init(rawRepresentation: data) }
        let key = Curve25519.Signing.PrivateKey()
        try write(key.rawRepresentation, account: "device-ed25519")
        return key
    }
    struct StorageError: Error { let status: OSStatus }
}

struct UnknownHost: Error { let key: String; let fingerprint: String }
struct ChangedHost: Error {}
final class PinnedHostValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let expected: String?
    private let lock = NSLock()
    private var rejection: Error?
    init(expected: String?) { self.expected = expected }
    var verificationError: Error? { lock.withLock { rejection } }
    private func reject(_ error: Error, promise: EventLoopPromise<Void>) {
        lock.withLock { rejection = error }
        promise.fail(error)
    }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let actual = String(openSSHPublicKey: hostKey)
        guard let expected else {
            reject(UnknownHost(key: actual, fingerprint: SSHPrimitives.fingerprint(hostKey)), promise: validationCompletePromise)
            return
        }
        if expected == actual { validationCompletePromise.succeed(()) }
        else { reject(ChangedHost(), promise: validationCompletePromise) }
    }
}
