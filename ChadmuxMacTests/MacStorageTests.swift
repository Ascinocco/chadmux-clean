import XCTest
@testable import Chadmux

/// macOS specifics: owner-only files (no per-file protection classes), the
/// Mac's own device key, and suggesting this Mac as the first host.
@MainActor
final class MacStorageTests: XCTestCase {
    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testDraftsAndImagesAreOwnerOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = MacConnection(host: "mac.example", port: 22, username: "user")
        let recovery = RecoveryStore(directory: root.appendingPathComponent("drafts"))
        try recovery.save(SavedWorkspace(profile: profile, selectedID: nil, tabs: []))
        XCTAssertEqual(try permissions(recovery.directory), 0o700)
        XCTAssertEqual(try permissions(recovery.url(for: profile)), 0o600)
        let media = MediaStore(directory: root.appendingPathComponent("images"))
        let attachment = try await media.importImage(TestImages.png(.blue))
        XCTAssertEqual(try permissions(media.directory), 0o700)
        XCTAssertEqual(try permissions(media.url(for: attachment)), 0o600)
    }

    func testTheMacHasItsOwnStableDeviceKey() throws {
        let mac = SecretStore(service: "com.chadmux.mac-key-tests." + UUID().uuidString)
        let other = SecretStore(service: "com.chadmux.mac-key-tests." + UUID().uuidString)
        defer { try? mac.remove("device-ed25519"); try? other.remove("device-ed25519") }
        let first = try mac.deviceKey(), again = try mac.deviceKey()
        XCTAssertEqual(first.publicKey.rawRepresentation, again.publicKey.rawRepresentation, "created once, then reused")
        XCTAssertNotEqual(first.publicKey.rawRepresentation, try other.deviceKey().publicKey.rawRepresentation, "each device has its own key")
        XCTAssertTrue(SSHPrimitives.authorizedKey(first).hasPrefix("ssh-ed25519 "))
        try mac.remove("device-ed25519")
        XCTAssertNotEqual(first.publicKey.rawRepresentation, try mac.deviceKey().publicKey.rawRepresentation, "a removed key is replaced, not recovered")
    }

    func testThisMacIsTheFirstHostSuggestion() {
        let suggestion = HostProfile.firstHostSuggestion
        XCTAssertEqual(suggestion.label, "This Mac")
        XCTAssertEqual(suggestion.connection, MacConnection(host: "localhost", port: 22, username: NSUserName()))
        XCTAssertNil(suggestion.problem)
        XCTAssertTrue(HostProfile.isThisMac("localhost")); XCTAssertTrue(HostProfile.isThisMac("127.0.0.1"))
        XCTAssertFalse(HostProfile.isThisMac("arch.example"))
    }
}
