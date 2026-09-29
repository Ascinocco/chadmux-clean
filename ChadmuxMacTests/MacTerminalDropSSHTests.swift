import XCTest
import Citadel
import Crypto
import NIOSSH
import Logging
@testable import Chadmux

/// Mac only: an image dropped on the terminal reaches the host over SFTP and its
/// path is pasted into the pane, with no Enter (the disposable sshd, or Linux).
extension SSHIntegrationTests {
    @MainActor
    func testMacTerminalDropUploadsAndPastesThePath() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else { throw XCTSkip("Disposable fixture required") }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let service = "com.chadmux.drop-fixture." + UUID().uuidString
        let prefs = UserDefaults(suiteName: service)!
        let secrets = SecretStore(service: service)
        let profile = MacConnection(host: "127.0.0.1", port: f.port, username: f.username)
        try secrets.write(try Curve25519.Signing.PrivateKey(sshEd25519: f.privateKey).rawRepresentation, account: "device-ed25519")
        try secrets.write(Data(String(openSSHPublicKey: try NIOSSHPublicKey(openSSHPublicKey: f.hostKey)).utf8), account: profile.trustID)
        let control = MacTransport(preferences: prefs, secrets: secrets)
        try control.save(profile)
        control.connect(openShell: false)
        for _ in 0..<100 where !control.connected { try await Task.sleep(nanoseconds: 100_000_000) }
        let client = try XCTUnwrap(control.client)
        let q = SSHPrimitives.shellQuote
        let tmux = "/usr/bin/env LC_ALL=en_US.UTF-8 " + q(f.tmux) + " -u -f /dev/null -S " + q(f.tmuxSocket)
        let workspace = SessionWorkspace(connection: control, tmuxCommand: tmux)
        workspace.uploadRoot = f.uploadRoot
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("chadmux-drop-ssh-" + UUID().uuidString)
        defer {
            workspace.disconnect(); prefs.removePersistentDomain(forName: service)
            try? secrets.remove("device-ed25519"); try? secrets.remove(profile.trustID)
            try? FileManager.default.removeItem(at: local)
        }
        // A pane that records every byte it receives, with bracketed paste on (as Claude's prompt).
        let receiver = "exec " + q(f.python) + " " + q(f.composerReceiver) + " " + q(f.composerCapture)
        _ = try await client.executeCommand(tmux + " new-session -d -s drop " + q(receiver), maxResponseSize: 1024)
        await workspace.refresh()
        workspace.becameActive(); workspace.select(try XCTUnwrap(workspace.sessions.first { $0.name == "drop" }))
        let tab = try XCTUnwrap(workspace.selected)
        for _ in 0..<100 {
            if tab.transport.connected && String(decoding: tab.transport.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("READY") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(tab.transport.terminal.getTerminal().bracketedPasteMode)

        let store = MediaStore(directory: local)
        let transport = tab.transport, root = workspace.uploadRoot
        var paths: [String] = []
        let drop = TerminalImageDrop(media: store,
            upload: { attachments in
                paths = try await PhotoUpload.upload(attachments, store: store, settings: try transport.pinnedUploadSettings(), root: root)
                return paths
            },
            write: { try await transport.sendBytes($0) },
            ready: { transport.connected },
            bracketed: { transport.terminal.getTerminal().bracketedPasteMode })
        await drop.add([TestImages.png(.red), TestImages.png(.blue)], host: "Mac")
        XCTAssertEqual(drop.state, .added(2))
        XCTAssertEqual(paths.count, 2)

        // The pane received exactly the bracketed paths: no Enter, nothing else.
        let expected = TerminalImageDrop.pasteBytes(paths, bracketed: true)
        let capture = "if test -f " + q(f.composerCapture) + "; then od -An -tx1 " + q(f.composerCapture) + " | tr -d ' \\n'; fi"
        try await eventually(client, command: capture, equals: expected.map { String(format: "%02x", $0) }.joined())
        // What the pane received: the paths inside one bracketed paste, and no Enter.
        let received = try await client.executeCommand(capture, maxResponseSize: 65536)
        let hex = String(buffer: received).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(hex.hasPrefix("1b5b3230307e") && hex.hasSuffix("1b5b3230317e"), hex)
        XCTAssertFalse(stride(from: 0, to: hex.count, by: 2).contains { hex.dropFirst($0).prefix(2) == "0d" || hex.dropFirst($0).prefix(2) == "0a" },
                       "no carriage return or newline reached the pane")

        // Each path is an owner-only JPEG on the host, under the upload root.
        let sftp = try await client.openSFTP(logger: Logger(label: "fixture.sftp", factory: { _ in SwiftLogNoOpLogHandler() }))
        for remote in paths {
            XCTAssertTrue(remote.hasPrefix("/") && remote.contains(f.uploadRoot), remote)
            let attributes = try await sftp.getAttributes(at: remote)
            XCTAssertEqual((attributes.permissions ?? 0) & 0o777, 0o600)
            let bytes = try await sftp.withFile(filePath: remote, flags: .read) { try await $0.readAll() }
            XCTAssertEqual(Array(Data(bytes.readableBytesView).prefix(3)), [0xFF, 0xD8, 0xFF], "re-encoded as JPEG")
        }
        try await sftp.close()
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: local.path)) ?? [], [], "no local copies left")
        _ = try await client.executeCommand(tmux + " kill-server", maxResponseSize: 1024)
    }
}
