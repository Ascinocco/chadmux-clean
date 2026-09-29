import XCTest
import Citadel
import Crypto
import NIO
import NIOSSH
import Logging
#if os(iOS)
import UIKit
#endif
@testable import Chadmux

final class SSHIntegrationTests: XCTestCase {
    struct Fixture: Decodable {
        let hostKey, privateKey, username, tmux, tmuxSocket, capture, receiver, python, composerReceiver, composerCapture, slowTmux, uploadRoot, stallStarted, stallClosed: String
        let port: Int
        let apiPort: Int
        let stallPort: Int
        let residentTokenFile: String?
        let residentAudio: [String]?
        let claudeTmux, fixtureBin, noClaudeScript, projectsDir: String?
        let macTmux, macTmuxSocket, archTmux, archTmuxSocket: String?
        let macPort, archPort: Int?
        let linux: Bool?
    }

    func request(cols: Int, rows: Int) -> SSHChannelRequestEvent.PseudoTerminalRequest {
        .init(wantReply: true, term: "xterm-256color", terminalCharacterWidth: cols,
              terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))
    }

    func pty(_ client: SSHClient, cols: Int, rows: Int,
             perform: (TTYOutput, TTYStdinWriter) async throws -> Void) async throws {
        var completed = false
        do {
            try await client.withPTY(request(cols: cols, rows: rows)) { inbound, writer in
                try await perform(inbound, writer)
                completed = true
            }
        } catch ChannelError.alreadyClosed {
            // Only suppress Citadel's duplicate close after successful stream completion.
            XCTAssertTrue(completed, "A failed or incomplete stream must not look successful")
            if !completed { throw ChannelError.alreadyClosed }
        }
    }

    func eventually(_ client: SSHClient, command: String, equals expected: String) async throws {
        var actual = ""
        for _ in 0..<40 {
            actual = String(buffer: try await client.executeCommand(command, maxResponseSize: 8192))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if actual == expected { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(actual, expected)
    }

    func testPinnedKeyAuthenticationPTYAndResize() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else {
            throw XCTSkip("Run scripts/test-transport.py for the disposable SSH integration fixture")
        }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: f.privateKey)
        let hostKey = try NIOSSHPublicKey(openSSHPublicKey: f.hostKey)
        let settings = SSHClientSettings(host: "127.0.0.1", port: f.port,
            authenticationMethod: { .ed25519(username: f.username, privateKey: key) },
            hostKeyValidator: .trustedKeys([hostKey]))
        let client = try await SSHClient.connect(to: settings)
        let q = SSHPrimitives.shellQuote
        let tmux = q(f.tmux) + " -f /dev/null -S " + q(f.tmuxSocket)
        do {
            let execResult = try await client.executeCommand("printf 'chadmux-exec-ok'", maxResponseSize: 1024)
            XCTAssertEqual(String(buffer: execResult), "chadmux-exec-ok")
            try await pty(client, cols: 80, rows: 24) { inbound, writer in
                try await writer.changeSize(cols: 42, rows: 19, pixelWidth: 0, pixelHeight: 0)
                try await writer.write(ByteBuffer(string: "stty -echo; printf '\\nPTY_SIZE='; stty size; printf 'UTF8=你好\\n'; exit\n"))
                var output = ""
                for try await item in inbound {
                    switch item { case .stdout(let b), .stderr(let b): output += String(buffer: b) }
                }
                XCTAssertTrue(output.contains("PTY_SIZE=19 42"))
                XCTAssertTrue(output.contains("UTF8=你好"))
            }
            let receiver = "stty -echo; exec " + q(f.python) + " " + q(f.receiver) + " " + q(f.capture)
            _ = try await client.executeCommand(tmux + " new-session -d -s sample -x 100 -y 30 " + q(receiver), maxResponseSize: 1024)
            _ = try await client.executeCommand(tmux + " set-window-option -g window-size latest", maxResponseSize: 1024)
            let count = tmux + " list-clients -F '#{client_name}' | wc -l | tr -d ' '"
            let size = tmux + " display-message -p -t sample '#{window_width}x#{window_height}'"
            // Keep the desktop attached while the phone joins, rotates and detaches.
            try await pty(client, cols: 100, rows: 30) { desktopOutput, desktop in
                try await desktop.write(ByteBuffer(string: tmux + " attach-session -t sample; exit\n"))
                try await eventually(client, command: count, equals: "1")
                try await pty(client, cols: 42, rows: 19) { phoneOutput, phone in
                    try await phone.write(ByteBuffer(string: tmux + " attach-session -t sample; exit\n"))
                    try await eventually(client, command: count, equals: "2")
                    try await phone.changeSize(cols: 42, rows: 19, pixelWidth: 0, pixelHeight: 0)
                    try await eventually(client, command: size, equals: "42x18")
                    try await phone.write(ByteBuffer(string: "first line\nsecond literal $(not-a-command) 你好\n"))
                    let captured = "if test -f " + q(f.capture) + "; then cat " + q(f.capture) + "; fi"
                    let expected = "[\"first line\", \"second literal $(not-a-command) \\u4f60\\u597d\"]"
                    try await eventually(client, command: captured, equals: expected)
                    try await phone.changeSize(cols: 80, rows: 19, pixelWidth: 0, pixelHeight: 0)
                    try await eventually(client, command: size, equals: "80x18")
                    try await phone.write(ByteBuffer(bytes: [2, 100]))
                    for try await _ in phoneOutput {}
                }
                try await eventually(client, command: count, equals: "1")
                try await eventually(client, command: size, equals: "100x29")
                try await desktop.write(ByteBuffer(bytes: [2, 100]))
                for try await _ in desktopOutput {}
            }
            _ = try await client.executeCommand(tmux + " has-session -t sample", maxResponseSize: 1024)
            _ = try await client.executeCommand(tmux + " kill-server", maxResponseSize: 1024)
            try await client.close()
        } catch {
            _ = try? await client.executeCommand(tmux + " kill-server", maxResponseSize: 1024)
            try? await client.close()
            throw error
        }
        let wrongKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let verifier = PinnedHostValidator(expected: String(openSSHPublicKey: wrongKey))
        let rejected = SSHClientSettings(host: "127.0.0.1", port: f.port,
            authenticationMethod: { .ed25519(username: f.username, privateKey: key) },
            hostKeyValidator: .custom(verifier))
        do {
            let unsafe = try await SSHClient.connect(to: rejected)
            try? await unsafe.close()
            XCTFail("A changed server key must be rejected")
        } catch { XCTAssertTrue(verifier.verificationError is ChangedHost, "The actual host validator must reject; an unrelated network failure is not evidence") }
    }
}


extension SSHIntegrationTests {
    @MainActor
    func testAppConnectionTrustPTYAndLoopbackForwarding() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else {
            throw XCTSkip("Run scripts/test-transport.py for the disposable SSH integration fixture")
        }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let name = "com.chadmux.integration." + UUID().uuidString
        let store = SecretStore(service: name)
        let prefs = UserDefaults(suiteName: name)!
        let profile = MacConnection(host: "127.0.0.1", port: f.port, username: f.username)
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: f.privateKey)
        try store.write(key.rawRepresentation, account: "device-ed25519")
        let model = MacTransport(preferences: prefs, secrets: store)
        defer {
            model.disconnect(); prefs.removePersistentDomain(forName: name)
            try? store.remove("device-ed25519"); try? store.remove(profile.trustID)
        }
        try model.save(profile)
        model.connect()
        for _ in 0..<100 {
            if !model.connecting { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(model.unknownHost)
        XCTAssertFalse(model.connected)
        model.trustHost()
        for _ in 0..<100 {
            if model.connected || !model.connecting { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(model.connected, model.status)
        let client = try XCTUnwrap(model.client)
        try await model.sendBytes(Array("printf 'APP_%s_OK\\n' 'PTY'\n".utf8))
        var rendered = false
        // A login shell can take seconds to start (profile scripts, a loaded machine).
        for _ in 0..<100 {
            let buffer = model.terminal.getTerminal().getBufferAsData()
            rendered = String(decoding: buffer, as: UTF8.self).contains("APP_PTY_OK")
            if rendered { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(rendered, "Actual server output must reach the retained terminal")
        let reply = try await LoopbackAPI.transcribe(client: client, recording: Data("synthetic-recording".utf8),
                                                   token: "fixture-transcription-token", port: f.apiPort)
        XCTAssertEqual(reply.text, "Forwarded safely over SSH")
        do {
            _ = try await LoopbackAPI.transcribe(client: client, recording: Data("synthetic-recording".utf8),
                                               token: "fixture-transcription-token", port: 1)
            XCTFail("Unavailable forwarding must fail")
        } catch { XCTAssertTrue(client.isConnected, "Optional API failure must not disconnect SSH") }
        let output = try await client.executeCommand("printf 'STILL_CONNECTED'", maxResponseSize: 100)
        XCTAssertEqual(String(buffer: output), "STILL_CONNECTED")
        model.disconnect()
        XCTAssertFalse(model.connected)
        try store.write(Data("changed fixture host".utf8), account: profile.trustID)
        model.connect()
        for _ in 0..<100 {
            if !model.connecting { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.status, "Host key changed")
        XCTAssertNil(model.unknownHost)
        XCTAssertFalse(model.connected)
    }
}


extension SSHIntegrationTests {
    @MainActor
    func testTwoSessionsSwitchDraftsAndDetachWithoutKilling() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else { throw XCTSkip("Disposable fixture required") }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let name = "com.chadmux.sessions." + UUID().uuidString
        let secrets = SecretStore(service: name)
        let prefs = UserDefaults(suiteName: name)!
        let profile = MacConnection(host: "127.0.0.1", port: f.port, username: f.username)
        try secrets.write(try Curve25519.Signing.PrivateKey(sshEd25519: f.privateKey).rawRepresentation, account: "device-ed25519")
        let trusted = String(openSSHPublicKey: try NIOSSHPublicKey(openSSHPublicKey: f.hostKey))
        try secrets.write(Data(trusted.utf8), account: profile.trustID)
        let control = MacTransport(preferences: prefs, secrets: secrets)
        try control.save(profile)
        control.connect(openShell: false)
        for _ in 0..<100 {
            if control.connected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let client = try XCTUnwrap(control.client)
        let q = SSHPrimitives.shellQuote
        let command = "/usr/bin/env LC_ALL=en_US.UTF-8 " + q(f.tmux) + " -u -f /dev/null -S " + q(f.tmuxSocket)
        let workspace = SessionWorkspace(connection: control, tmuxCommand: command)
        defer {
            workspace.disconnect(); prefs.removePersistentDomain(forName: name)
            try? secrets.remove("device-ed25519"); try? secrets.remove(profile.trustID)
        }
        let unusual = "alpha $(not-a-command) 你好"
        _ = try await client.executeCommand(command + " new-session -d -s " + q(unusual) + " /bin/cat", maxResponseSize: 1024)
        _ = try await client.executeCommand(command + " new-session -d -s beta /bin/cat", maxResponseSize: 1024)
        let discovered = try await TmuxSessions.list(using: client, command: command)
        XCTAssertEqual(discovered.count, 2)
        await workspace.refresh()
        XCTAssertEqual(workspace.sessions.count, 2, workspace.error ?? control.status)
        let a = try XCTUnwrap(workspace.sessions.first(where: { $0.name == unusual }))
        let b = try XCTUnwrap(workspace.sessions.first(where: { $0.name == "beta" }))
        workspace.becameActive(); workspace.select(a)
        let tabA = try XCTUnwrap(workspace.selected)
        tabA.draft = "Keep this draft"
        tabA.attachments = [DraftAttachment(filename: "synthetic.jpg")]
        for _ in 0..<100 {
            if tabA.transport.connected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        workspace.becameActive(); workspace.select(b)
        let tabB = try XCTUnwrap(workspace.selected)
        tabB.draft = "Second draft"
        for _ in 0..<100 {
            if tabB.transport.connected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(tabA.transport.connected)
        XCTAssertTrue(tabB.transport.connected)
        XCTAssertFalse(tabA.transport.terminal === tabB.transport.terminal)
        try await eventually(client, command: command + " list-clients -F '#{client_name}' | wc -l | tr -d ' '", equals: "2")
        try await tabA.transport.sendBytes(Array("ROUTED_TO_ALPHA\n".utf8))
        try await Task.sleep(nanoseconds: 150_000_000)
        let captureA = String(buffer: try await client.executeCommand(command + " capture-pane -p -t " + q(a.id), maxResponseSize: 16384))
        let captureB = String(buffer: try await client.executeCommand(command + " capture-pane -p -t " + q(b.id), maxResponseSize: 16384))
        XCTAssertTrue(captureA.contains("ROUTED_TO_ALPHA"))
        XCTAssertFalse(captureB.contains("ROUTED_TO_ALPHA"))
        workspace.becameActive(); workspace.select(a)
        XCTAssertTrue(workspace.selected === tabA)
        XCTAssertEqual(tabA.draft, "Keep this draft")
        XCTAssertEqual(tabA.attachments.count, 1)
        XCTAssertEqual(tabB.draft, "Second draft")
        workspace.close(a.id)
        try await eventually(client, command: command + " list-clients -F '#{client_name}' | wc -l | tr -d ' '", equals: "1")
        _ = try await client.executeCommand(command + " has-session -t " + q(a.id), maxResponseSize: 1024)
        _ = try await client.executeCommand(command + " kill-session -t " + q(b.id), maxResponseSize: 1024)
        await workspace.refresh()
        XCTAssertEqual(tabB.draft, "Second draft")
        XCTAssertEqual(tabB.transport.status, "Session no longer exists")
        workspace.close(b.id)
        workspace.becameActive(); workspace.select(a)
        let retained = try XCTUnwrap(workspace.selected)
        retained.draft = "Preserve after tmux restart"
        _ = try await client.executeCommand(command + " kill-server", maxResponseSize: 1024)
        _ = try await client.executeCommand(command + " new-session -d -s replacement /bin/cat", maxResponseSize: 1024)
        await workspace.refresh()
        let replacement = try XCTUnwrap(workspace.sessions.first)
        XCTAssertEqual(replacement.id, a.id)
        XCTAssertNotEqual(replacement.instance, a.instance)
        workspace.becameActive(); workspace.select(replacement)
        XCTAssertFalse(retained.transport.connected)
        XCTAssertEqual(retained.draft, "Preserve after tmux restart")
        XCTAssertNotNil(workspace.error)
        workspace.close(a.id)
        _ = try await client.executeCommand(command + " kill-server", maxResponseSize: 1024)
    }
    @MainActor
    func testComposerDeliversLiteralPasteAndControlsThroughRealTmux() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else { throw XCTSkip("Run disposable transport fixture") }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:URL(fileURLWithPath:path)))
        let service = "com.chadmux.composer-fixture." + UUID().uuidString
        let prefs = UserDefaults(suiteName:service)!
        let secrets = SecretStore(service:service)
        let profile = MacConnection(host:"127.0.0.1",port:f.port,username:f.username)
        let key = try Curve25519.Signing.PrivateKey(sshEd25519:f.privateKey)
        try secrets.write(key.rawRepresentation,account:"device-ed25519")
        let host = String(openSSHPublicKey:try NIOSSHPublicKey(openSSHPublicKey:f.hostKey))
        try secrets.write(Data(host.utf8),account:profile.trustID)
        let control = MacTransport(preferences:prefs,secrets:secrets)
        try control.save(profile)
        control.connect(openShell:false)
        for _ in 0..<100 {
            if control.connected { break }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        let client = try XCTUnwrap(control.client)
        let q = SSHPrimitives.shellQuote
        let command = "/usr/bin/env LC_ALL=en_US.UTF-8 " + q(f.slowTmux) + " -u -f /dev/null -S " + q(f.tmuxSocket)
        let workspace = SessionWorkspace(connection:control,tmuxCommand:command)
        defer {
            workspace.disconnect(); prefs.removePersistentDomain(forName:service)
            try? secrets.remove("device-ed25519"); try? secrets.remove(profile.trustID)
        }
        let receiver = "exec " + q(f.python) + " " + q(f.composerReceiver) + " " + q(f.composerCapture)
        _ = try await client.executeCommand(command + " new-session -d -s composer " + q(receiver), maxResponseSize:1024)
        await workspace.refresh()
        workspace.becameActive(); workspace.select(try XCTUnwrap(workspace.sessions.first))
        let tab = try XCTUnwrap(workspace.selected)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertFalse(tab.transport.connected, "The delayed tmux attachment must not expose its login shell as ready")
        tab.draft = "Too early"
        await tab.submit()
        XCTAssertEqual(tab.draft, "Too early")
        for _ in 0..<100 {
            if tab.transport.connected && String(decoding:tab.transport.terminal.getTerminal().getBufferAsData(),as:UTF8.self).contains("READY") { break }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        XCTAssertTrue(tab.transport.connected)
        XCTAssertTrue(tab.transport.terminal.getTerminal().bracketedPasteMode)
        let message = "first line\nsecond $(not-a-command) 你好"
        tab.draft = message
        await tab.submit()
        XCTAssertEqual(tab.draft, "")
        XCTAssertFalse(tab.deliveryUncertain)
        var expected = try ComposedMessage.bytes(message)
        for key in [TerminalControl.escape, .tab, .up, .enter, .interrupt] {
            let bytes = key.bytes(applicationCursor:tab.transport.terminal.getTerminal().applicationCursor)
            // tmux converts its client application-cursor encoding back to
            // the raw receiver pane's normal cursor mode.
            expected += key.bytes(applicationCursor:false)
            try await tab.transport.sendBytes(bytes)
        }
        let capture = "if test -f " + q(f.composerCapture) + "; then od -An -tx1 " + q(f.composerCapture) + " | tr -d ' \\n'; fi"
        try await eventually(client, command:capture, equals:expected.map { String(format:"%02x",$0) }.joined())
        _ = try await client.executeCommand(command + " kill-server",maxResponseSize:1024)
    }

    @MainActor
    func testPhotosUseSFTPAndInterruptedBatchNeverSubmits() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else { throw XCTSkip("Disposable fixture required") }
        let f = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let key = try Curve25519.Signing.PrivateKey(sshEd25519:f.privateKey)
        let host = try NIOSSHPublicKey(openSSHPublicKey:f.hostKey)
        let settings = SSHClientSettings(host:"127.0.0.1",port:f.port,authenticationMethod:{ .ed25519(username:f.username,privateKey:key) },hostKeyValidator:.trustedKeys([host]))
        let client = try await SSHClient.connect(to:settings)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MediaStore(directory:local)
        defer { try? FileManager.default.removeItem(at:local) }
        let first = try await store.importImage(TestImages.png(.red))
        let second = try await store.importImage(TestImages.png(.blue))
        let paths = try await PhotoUpload.upload([first,second],store:store,settings:settings,root:f.uploadRoot)
        XCTAssertEqual(paths.count,2)
        XCTAssertNotEqual(paths[0],paths[1])
        let logger = Logger(label:"fixture.sftp",factory:{ _ in SwiftLogNoOpLogHandler() })
        let sftp = try await client.openSFTP(logger:logger)
        for (attachment,remote) in zip([first,second],paths) {
            let attrs = try await sftp.getAttributes(at:remote)
            XCTAssertEqual((attrs.permissions ?? 0) & 0o777,0o600)
            let bytes = try await sftp.withFile(filePath:remote,flags:.read) { try await $0.readAll() }
            XCTAssertEqual(Data(bytes.readableBytesView),try store.data(for:attachment))
        }
        let directory = try await sftp.getAttributes(at:f.uploadRoot)
        XCTAssertEqual((directory.permissions ?? 0) & 0o777,0o700)
        try await sftp.close()

        let secrets = SecretStore(service:"com.chadmux.photo-fixture."+UUID().uuidString)
        defer { try? secrets.remove("device-ed25519") }
        let tab = SessionTab(session:RemoteSession(id:"$0",name:"Fixture"),profile:MacConnection(),secrets:secrets,media:store)
        tab.draft = "Keep both images"; tab.attachments = [first,second]
        var writes = 0
        let firstUploaded = client.eventLoop.makePromise(of: Void.self)
        let releaseProgress = client.eventLoop.makePromise(of: Void.self)
        let upload = Task { await tab.submit(pasteEnabled:true,prepare:{ selected in
            try await PhotoUpload.upload(selected,store:store,settings:settings,root:f.uploadRoot) { completed, _ in
                if completed == 1 { firstUploaded.succeed(()); try? await releaseProgress.futureResult.get() }
            }
        }) { _ in writes += 1 } }
        try await firstUploaded.futureResult.get()
        upload.cancel() // closes only the separately owned upload SSH transport
        releaseProgress.succeed(())
        await upload.value
        XCTAssertEqual(writes,0)
        XCTAssertEqual(tab.attachments,[first,second])
        XCTAssertEqual(tab.draft,"Keep both images")
        XCTAssertFalse(tab.deliveryUncertain)
        XCTAssertNotNil(try? store.data(for:first))
        XCTAssertNotNil(try? store.data(for:second))
        XCTAssertTrue(client.isConnected)
        try await client.close()
    }

    @MainActor
    func testStalledSFTPInitializationClosesUploadWithoutClosingTerminal() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else { throw XCTSkip("Disposable fixture required") }
        let f = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let key = try Curve25519.Signing.PrivateKey(sshEd25519:f.privateKey)
        let host = try NIOSSHPublicKey(openSSHPublicKey:f.hostKey)
        let normal = SSHClientSettings(host:"127.0.0.1",port:f.port,authenticationMethod:{ .ed25519(username:f.username,privateKey:key) },hostKeyValidator:.trustedKeys([host]))
        var stalled = normal; stalled.port = f.stallPort
        let terminal = try await SSHClient.connect(to:normal)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = MediaStore(directory:root)
        let photo = try await store.importImage(TestImages.png())
        let q = SSHPrimitives.shellQuote
        for cancel in [true,false] {
            _ = try await terminal.executeCommand("rm -f " + q(f.stallStarted) + " " + q(f.stallClosed),maxResponseSize:128)
            let started = Date()
            let settings = stalled
            let upload = Task { try await PhotoUpload.upload([photo],store:store,settings:settings,root:f.uploadRoot,timeout:.milliseconds(1500)) }
            try await eventually(terminal,command:"test -f " + q(f.stallStarted) + " && printf started || true",equals:"started")
            if cancel { upload.cancel() }
            do { _ = try await upload.value; XCTFail("Stalled initialization must not succeed") }
            catch { XCTAssertTrue(error is CancellationError || error is LoopbackAPI.Unavailable) }
            XCTAssertLessThan(Date().timeIntervalSince(started),3)
            try await eventually(terminal,command:"test -f " + q(f.stallClosed) + " && cat " + q(f.stallClosed) + " || true",equals:"closed")
            XCTAssertTrue(terminal.isConnected)
            let check = try await terminal.executeCommand("printf TERMINAL_OK",maxResponseSize:128)
            XCTAssertEqual(String(buffer:check),"TERMINAL_OK")
        }
        // Return an actual connected SSH transport only after its caller timed out.
        let late = try await SSHClient.connect(to:normal)
        let release = terminal.eventLoop.makePromise(of:Void.self)
        do {
            let _: Int = try await PhotoUpload.withOwnedConnection(on:terminal.eventLoop,timeout:.milliseconds(20),connect:{
                try await release.futureResult.get(); return late
            }) { _ in XCTFail("Late resource must never begin SFTP"); return 1 }
            XCTFail("Expected deadline")
        } catch { XCTAssertTrue(error is LoopbackAPI.Unavailable) }
        release.succeed(())
        for _ in 0..<50 {
            if !late.isConnected { break }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        XCTAssertFalse(late.isConnected)
        XCTAssertTrue(terminal.isConnected)
        try await terminal.close()
    }

    func testResidentDictationThroughSSHLatency() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else {
            throw XCTSkip("Run the transport fixture with --resident-token-file for resident dictation")
        }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let tokenFile = f.residentTokenFile, let recordings = f.residentAudio else { throw XCTSkip("Resident dictation is explicitly opt-in") }
        let token = try String(contentsOfFile: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: f.privateKey)
        let host = try NIOSSHPublicKey(openSSHPublicKey: f.hostKey)
        let client = try await SSHClient.connect(to: SSHClientSettings(host: "127.0.0.1", port: f.port,
            authenticationMethod: { .ed25519(username: f.username, privateKey: key) }, hostKeyValidator: .trustedKeys([host])))
        do {
            for path in recordings {
                for iteration in 0..<3 {
                    let started = ContinuousClock.now
                    let audio = try Data(contentsOf: URL(fileURLWithPath: path))
                    let reply = try await LoopbackAPI.transcribe(client: client, recording: audio, token: token)
                    let elapsed = started.duration(to: .now)
                    XCTAssertTrue(reply.text.lowercased().contains("unit test"))
                    XCTAssertTrue(reply.text.lowercased().contains("code"))
                    XCTAssertLessThanOrEqual(reply.duration_seconds, 30)
                    // First request is a warm-up, reported separately from target samples.
                    print("Resident synthetic dictation: duration=\(reply.duration_seconds)s iteration=\(iteration) elapsed=\(elapsed)")
                    if iteration > 0 { XCTAssertLessThan(elapsed, .seconds(2), "Warm local SSH dictation exceeded the two-second target") }
                }
            }
            let result = try await client.executeCommand("printf 'terminal-still-available'", maxResponseSize: 64)
            XCTAssertEqual(String(buffer: result), "terminal-still-available")
            try await client.close()
        } catch { try? await client.close(); throw error }
    }

    @MainActor
    func testIntegratedDictationPhotosRelaunchAndExplicitTerminalSend() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else { throw XCTSkip("Disposable fixture required") }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let service = "com.chadmux.integrated-fixture." + UUID().uuidString
        let prefs = UserDefaults(suiteName: service)!, secrets = SecretStore(service: service)
        let profile = MacConnection(host: "127.0.0.1", port: f.port, username: f.username)
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: f.privateKey)
        let host = String(openSSHPublicKey: try NIOSSHPublicKey(openSSHPublicKey: f.hostKey))
        try secrets.write(key.rawRepresentation, account: "device-ed25519")
        try secrets.write(Data(host.utf8), account: profile.trustID)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recovery = RecoveryStore(directory: root.appendingPathComponent("drafts")), media = MediaStore(directory: root.appendingPathComponent("media"))
        defer {
            try? FileManager.default.removeItem(at: root); prefs.removePersistentDomain(forName: service)
            try? secrets.remove("device-ed25519"); try? secrets.remove(profile.trustID)
        }
        let control = MacTransport(preferences: prefs, secrets: secrets)
        try control.save(profile); control.connect(openShell: false)
        for _ in 0..<100 { if control.connected { break }; try await Task.sleep(for: .milliseconds(100)) }
        let client = try XCTUnwrap(control.client), q = SSHPrimitives.shellQuote
        let command = "/usr/bin/env LC_ALL=en_US.UTF-8 " + q(f.tmux) + " -u -f /dev/null -S " + q(f.tmuxSocket)
        let receiver = "exec " + q(f.python) + " " + q(f.composerReceiver) + " " + q(f.composerCapture)
        _ = try await client.executeCommand(command + " new-session -d -s integrated " + q(receiver), maxResponseSize: 1024)
        _ = try await client.executeCommand(command + " new-session -d -s other /bin/cat", maxResponseSize: 1024)
        let workspace = SessionWorkspace(connection: control, tmuxCommand: command, recovery: recovery, media: media)
        defer { workspace.disconnect() }
        await workspace.refresh()
        let session = try XCTUnwrap(workspace.sessions.first { $0.name == "integrated" })
        let otherSession = try XCTUnwrap(workspace.sessions.first { $0.name == "other" })
        workspace.becameActive(); workspace.select(session)
        let original = try XCTUnwrap(workspace.selected)
        for _ in 0..<100 { if original.transport.connected { break }; try await Task.sleep(for: .milliseconds(100)) }
        original.draft = "Please inspect"
        let voice = VoiceCoordinator(permission: { true }, makeRecording: { FixtureRecording() })
        voice.start(tab: original) { data in
            try await LoopbackAPI.transcribe(client: client, recording: data, token: "fixture-transcription-token", port: f.apiPort).text
        }
        for _ in 0..<100 { if voice.phase == .recording { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(voice.phase, .recording)
        workspace.becameActive(); workspace.select(otherSession)
        let other = try XCTUnwrap(workspace.selected); other.draft = "Other session draft"
        voice.stop()
        for _ in 0..<100 { if !voice.active { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(original.draft, "Please inspect Forwarded safely over SSH")
        XCTAssertEqual(other.draft, "Other session draft")
        original.draft += "\nManual correction"
        for color in [TestImages.Color.red, .green, .blue] {
            original.attachments.append(try await media.importImage(TestImages.png(color)))
        }
        original.removeImage(original.attachments[1])
        XCTAssertEqual(original.attachments.count, 2)
        let expectedText = original.draft
        workspace.background()
        let secondControl = MacTransport(preferences: prefs, secrets: secrets)
        let restored = SessionWorkspace(connection: secondControl, tmuxCommand: command, recovery: recovery, media: media)
        defer { restored.disconnect() }
        let restoredOrigin = try XCTUnwrap(restored.tabs.first { $0.id == session.id })
        XCTAssertEqual(restoredOrigin.draft, expectedText); XCTAssertEqual(restoredOrigin.attachments.count, 2)
        XCTAssertFalse(secondControl.connected); XCTAssertFalse(restoredOrigin.transport.connecting)
        secondControl.connect(openShell: false)
        for _ in 0..<100 { if secondControl.connected { break }; try await Task.sleep(for: .milliseconds(100)) }
        await restored.refresh(); restored.becameActive(); restored.select(session)
        for _ in 0..<100 {
            if restoredOrigin.transport.connected && restoredOrigin.transport.terminal.getTerminal().bracketedPasteMode { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(restoredOrigin.transport.connected)
        var uploaded: [String] = []
        let settings = try restoredOrigin.transport.pinnedUploadSettings()
        await restoredOrigin.submit(pasteEnabled: restoredOrigin.transport.terminal.getTerminal().bracketedPasteMode,
            prepare: { selected in
                uploaded = try await PhotoUpload.upload(selected, store: media, settings: settings, root: f.uploadRoot)
                return uploaded
            }, ready: { restoredOrigin.transport.connected }) { bytes in
                try await restoredOrigin.transport.sendBytes(bytes)
            }
        XCTAssertEqual(uploaded.count, 2)
        XCTAssertEqual(restoredOrigin.draft, ""); XCTAssertTrue(restoredOrigin.attachments.isEmpty)
        let expected = try ComposedMessage.bytes(PhotoUpload.message(expectedText, paths: uploaded))
        let reconnected = try XCTUnwrap(secondControl.client)
        let capture = "if test -f " + q(f.composerCapture) + "; then od -An -tx1 " + q(f.composerCapture) + " | tr -d ' \n'; fi"
        try await eventually(reconnected, command: capture, equals: expected.map { String(format: "%02x", $0) }.joined())
        for path in uploaded { _ = try await reconnected.executeCommand("test -s " + q(path), maxResponseSize: 64) }
        let final = try XCTUnwrap(recovery.load(profile: profile))
        XCTAssertEqual(final.tabs.first { $0.session.id == session.id }?.draft, "")
        XCTAssertEqual(final.tabs.first { $0.session.id == otherSession.id }?.draft, "Other session draft")
        _ = try await reconnected.executeCommand(command + " kill-server", maxResponseSize: 1024)
    }

}


@MainActor
private final class FixtureRecording: VoiceRecording {
    func start(finished: @escaping (Bool) -> Void) throws {}
    func stop() throws -> Data { Data("synthetic-recording".utf8) }
    func discard() {}
}

extension SSHIntegrationTests {
    @MainActor
    func testNativeWheelTargetsRealPanesAndReturnCancelsOnlyActiveHistory() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else { throw XCTSkip("Run disposable transport fixture") }
        let f = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let name = "com.chadmux.native-transport." + UUID().uuidString
        let prefs = UserDefaults(suiteName:name)!, secrets = SecretStore(service:name)
        let profile = MacConnection(host:"127.0.0.1",port:f.port,username:f.username)
        let key = try Curve25519.Signing.PrivateKey(sshEd25519:f.privateKey)
        try secrets.write(key.rawRepresentation,account:"device-ed25519")
        try secrets.write(Data(String(openSSHPublicKey:try NIOSSHPublicKey(openSSHPublicKey:f.hostKey)).utf8),account:profile.trustID)
        let control = MacTransport(preferences:prefs,secrets:secrets)
        try control.save(profile); control.connect(openShell:false)
        for _ in 0..<100 { if control.connected { break }; try await Task.sleep(nanoseconds:100_000_000) }
        let client = try XCTUnwrap(control.client), q = SSHPrimitives.shellQuote
        let tmux = q(f.tmux)+" -f /dev/null -S "+q(f.tmuxSocket)
        let workspace = SessionWorkspace(connection:control,tmuxCommand:tmux)
        defer {
            workspace.disconnect(); prefs.removePersistentDomain(forName:name)
            try? secrets.remove("device-ed25519"); try? secrets.remove(profile.trustID)
        }
        let output = "i=0; while [ $i -lt 180 ]; do printf 'fixture %s café 你好\\n' \"$i\"; i=$((i+1)); done; sleep 120"
        _ = try await client.executeCommand(tmux+" new-session -d -s native-panes -x 80 -y 24 "+q(output),maxResponseSize:1024)
        _ = try await client.executeCommand(tmux+" split-window -h -t native-panes "+q(output),maxResponseSize:1024)
        _ = try await client.executeCommand(tmux+" set-option -t native-panes mouse on",maxResponseSize:1024)
        await workspace.refresh()
        let session = try XCTUnwrap(workspace.sessions.first(where:{$0.name=="native-panes"}))
        workspace.becameActive(); workspace.select(session)
        let transport = try XCTUnwrap(workspace.selected?.transport)
        for _ in 0..<100 { if transport.connected { break }; try await Task.sleep(nanoseconds:100_000_000) }
        XCTAssertTrue(transport.connected)
        try await Task.sleep(nanoseconds:300_000_000)
        let frame = transport.terminal.getOptimalFrameSize()
        let leftSelection = await transport.selectionRectangle(at:CGPoint(x:frame.width*0.2,y:frame.height*0.25))
        let rightSelection = await transport.selectionRectangle(at:CGPoint(x:frame.width*0.8,y:frame.height*0.25))
        XCTAssertLessThan(try XCTUnwrap(leftSelection).maxX,try XCTUnwrap(rightSelection).minX)
        XCTAssertTrue(try XCTUnwrap(leftSelection).contains(CGPoint(x:frame.width*0.2,y:frame.height*0.25)))
        XCTAssertTrue(try XCTUnwrap(rightSelection).contains(CGPoint(x:frame.width*0.8,y:frame.height*0.25)))
        transport.terminal.wheel(3,at:CGPoint(x:frame.width*0.2,y:frame.height*0.25))
        let modes = tmux+" list-panes -t native-panes -F '#{pane_index}:#{pane_in_mode}'"
        try await eventually(client,command:modes,equals:"0:1\n1:0")
        transport.terminal.wheel(3,at:CGPoint(x:frame.width*0.8,y:frame.height*0.25))
        try await eventually(client,command:modes,equals:"0:1\n1:1")
        await transport.returnToLive()
        try await eventually(client,command:modes,equals:"0:1\n1:0")
        await transport.returnToLive() // no key sent to a pane already live
        try await eventually(client,command:modes,equals:"0:1\n1:0")
        transport.disconnect()
        transport.terminal.wheel(8,at:CGPoint(x:frame.width*0.8,y:frame.height*0.25))
        workspace.becameActive(); workspace.select(session)
        for _ in 0..<100 { if transport.connected { break }; try await Task.sleep(nanoseconds:100_000_000) }
        XCTAssertTrue(transport.connected)
        try await eventually(client,command:modes,equals:"0:1\n1:0")
        _ = try await client.executeCommand(tmux+" kill-session -t native-panes",maxResponseSize:1024)
    }
}

extension SSHIntegrationTests {
    @MainActor
    func testForegroundResumeRealSSHIdentityNoReplayAndCancellation() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else { throw XCTSkip("Disposable fixture required") }
        let f = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let service = "com.chadmux.resume-live." + UUID().uuidString
        let prefs = UserDefaults(suiteName:service)!, secrets = SecretStore(service:service)
        let profile = MacConnection(host:"127.0.0.1",port:f.port,username:f.username)
        let trusted = String(openSSHPublicKey:try NIOSSHPublicKey(openSSHPublicKey:f.hostKey))
        try secrets.write(try Curve25519.Signing.PrivateKey(sshEd25519:f.privateKey).rawRepresentation,account:"device-ed25519")
        try secrets.write(Data(trusted.utf8),account:profile.trustID)
        let admin = MacTransport(preferences:prefs,secrets:secrets)
        try admin.save(profile); try await admin.connectAndWait(openShell:false)
        let client = try XCTUnwrap(admin.client), q = SSHPrimitives.shellQuote
        let command = q(f.tmux)+" -f /dev/null -S "+q(f.tmuxSocket)
        let capture = f.composerCapture+".resume"
        let receiver = "exec "+q(f.python)+" "+q(f.composerReceiver)+" "+q(capture)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recovery = RecoveryStore(directory:root.appendingPathComponent("drafts")), media = MediaStore(directory:root.appendingPathComponent("media"))
        let control = MacTransport(preferences:prefs,secrets:secrets)
        let workspace = SessionWorkspace(connection:control,tmuxCommand:command,recovery:recovery,media:media)
        defer {
            workspace.disconnect(); admin.disconnect()
            try? FileManager.default.removeItem(at:root); prefs.removePersistentDomain(forName:service)
            try? secrets.remove("device-ed25519"); try? secrets.remove(profile.trustID)
        }
        do {
            _ = try await client.executeCommand(command+" new-session -d -s resume-first "+q(receiver),maxResponseSize:1024)
            _ = try await client.executeCommand(command+" new-session -d -s resume-second /bin/cat",maxResponseSize:1024)
            workspace.becameActive(); workspace.retryConnection(); await workspace.waitForResume()
            let first = try XCTUnwrap(workspace.sessions.first{$0.name=="resume-first"})
            let second = try XCTUnwrap(workspace.sessions.first{$0.name=="resume-second"})
            workspace.select(second); await workspace.waitForResume()
            let other = try XCTUnwrap(workspace.selected); other.draft = "Other draft"
            workspace.select(first); await workspace.waitForResume()
            let selected = try XCTUnwrap(workspace.selected)
            XCTAssertTrue(selected.transport.connected)
            selected.draft = "NEVER-REPLAY"; selected.pendingTranscript = "Keep transcript"; selected.deliveryUncertain = true
            selected.attachments = [try await media.importImage(TestImages.png(.red))]
            let count = command+" list-clients -F '#{client_name}' | wc -l | tr -d ' '"
            try await eventually(client,command:count,equals:"2")
            workspace.background(); try await eventually(client,command:count,equals:"0")
            workspace.becameActive(); workspace.becameActive(); await workspace.waitForResume()
            XCTAssertTrue(selected.transport.connected); XCTAssertFalse(other.transport.connected)
            try await eventually(client,command:count,equals:"1")
            XCTAssertEqual(selected.draft,"NEVER-REPLAY"); XCTAssertTrue(selected.deliveryUncertain)
            // Receiver never sees draft, pending transcript, media paths or keys.
            let noReplay = String(buffer:try await client.executeCommand("test ! -e "+q(capture)+" && printf clean",maxResponseSize:1024))
            XCTAssertEqual(noReplay,"clean")
            workspace.background(); try await eventually(client,command:count,equals:"0")
            let restored = SessionWorkspace(connection:MacTransport(preferences:prefs,secrets:secrets),tmuxCommand:command,recovery:recovery,media:media)
            defer { restored.disconnect() }
            XCTAssertFalse(restored.connection.connected)
            restored.becameActive(); await restored.waitForResume()
            XCTAssertEqual(restored.selectedID,first.id); XCTAssertTrue(restored.selected!.transport.connected)
            XCTAssertEqual(restored.selected?.attachments,selected.attachments)
            XCTAssertEqual(restored.selected?.pendingTranscript,"Keep transcript"); XCTAssertTrue(restored.selected!.deliveryUncertain)
            try await eventually(client,command:count,equals:"1")
            let coldNoReplay = String(buffer:try await client.executeCommand("test ! -e "+q(capture)+" && printf clean",maxResponseSize:1024))
            XCTAssertEqual(coldNoReplay,"clean")
            restored.background(); try await eventually(client,command:count,equals:"0")
            // Exercise adapter completion itself: identity mismatch after handshake
            // must remain permanent even while its SSH channel closes.
            let wrong = MacTransport(preferences:prefs,secrets:secrets)
            do {
                try await wrong.connectAndWait(sessionID:first.id,expectedInstance:"replaced",tmuxCommand:command)
                XCTFail("Replaced identity must refuse attachment")
            } catch { XCTAssertEqual(error as? ConnectionFailure,.sessionUnavailable) }
            wrong.disconnect()
            // Deadline during a real delayed attach closes all clients, including
            // one whose shell finishes after cancellation.
            let slow = q(f.slowTmux)+" -f /dev/null -S "+q(f.tmuxSocket)
            let delayed = SessionWorkspace(connection:MacTransport(preferences:prefs,secrets:secrets),tmuxCommand:slow,recovery:recovery,media:media,resumeTimeout:0.25,resumeRetryDelay:0.01)
            delayed.becameActive()
            try await Task.sleep(for:.seconds(1.5))
            XCTAssertEqual(delayed.resumeState,.unavailable); XCTAssertFalse(delayed.connection.connected)
            XCTAssertFalse(delayed.selected!.transport.connected)
            try await eventually(client,command:count,equals:"0")
            delayed.background()
            // A dead session is not recreated by foreground return.
            _ = try await client.executeCommand(command+" kill-session -t "+q(first.id),maxResponseSize:1024)
            restored.becameActive(); await restored.waitForResume()
            XCTAssertEqual(restored.resumeState,.unavailable); XCTAssertFalse(restored.selected!.transport.connected)
            XCTAssertEqual(restored.selected?.draft,"NEVER-REPLAY")
            restored.background()
            try secrets.write(Data("different-host".utf8),account:profile.trustID)
            restored.becameActive(); await restored.waitForResume()
            XCTAssertEqual(restored.connection.status,"Host key changed"); XCTAssertNil(restored.verificationTransport)
            XCTAssertFalse(restored.connection.connected)
            _ = try await client.executeCommand(command+" kill-server",maxResponseSize:1024)
        } catch {
            _ = try? await client.executeCommand(command+" kill-server",maxResponseSize:1024)
            throw error
        }
    }
}


extension SSHIntegrationTests {
    /// Create and end sessions through the real claude-tmux script, over real SSH,
    /// against the fixture's private tmux server with a fake `claude`.
    @MainActor
    func testCreateAndEndSessionsThroughClaudeTmux() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else { throw XCTSkip("Disposable fixture required") }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let script = f.claudeTmux, let bin = f.fixtureBin, let projects = f.projectsDir, let noClaude = f.noClaudeScript else {
            throw XCTSkip("Pass --claude-tmux to test-transport.py (no claude-tmux script found)")
        }
        let name = "com.chadmux.claude-tmux." + UUID().uuidString
        let secrets = SecretStore(service: name)
        let prefs = UserDefaults(suiteName: name)!
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
        let claudeTmux = ClaudeTmux(scriptPath: script, pathPrefix: bin)
        let workspace = SessionWorkspace(connection: control, tmuxCommand: tmux, claudeTmux: claudeTmux)
        defer {
            workspace.disconnect(); prefs.removePersistentDomain(forName: name)
            try? secrets.remove("device-ed25519"); try? secrets.remove(profile.trustID)
        }
        func run(_ command: String) async throws -> String {
            String(buffer: try await client.executeCommand(command, maxResponseSize: 16384)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func describe(_ target: String) async throws -> String {
            try await run(tmux + " display-message -p -t " + q(target) + " '#{pane_start_command}|#{pane_current_path}|#{window_panes}'")
        }
        // Keep the private server alive for the whole test so session ids advance.
        _ = try await run(tmux + " new-session -d -s keepalive /bin/cat")
        // A hostile folder name must reach the script as one literal argument.
        let folder = projects + "/it's $(touch pwned) \"q\" dir"
        _ = try await run("mkdir -p " + q(folder))
        workspace.becameActive()

        // Create: listed, opened in a selected, attached tab, claude running in the folder.
        let created = await workspace.createSession(name: "phone-made", folder: folder)
        XCTAssertNil(created)
        let session = try XCTUnwrap(workspace.sessions.first { $0.name == "phone-made" })
        XCTAssertEqual(workspace.selectedID, session.id)
        await workspace.waitForResume()
        let tab = try XCTUnwrap(workspace.selected)
        XCTAssertTrue(tab.transport.connected, workspace.error ?? tab.transport.status)
        let observed1 = try await describe(session.id)
        XCTAssertEqual(observed1, "claude|" + folder + "|1")
        try await eventually(client, command: tmux + " capture-pane -p -t " + q(session.id) + " | grep -c FAKE-CLAUDE-READY", equals: "1")
        let observed2 = try await run("test -e " + q(projects + "/pwned") + " && echo yes || echo no")
        XCTAssertEqual(observed2, "no")
        XCTAssertEqual(workspace.newSessionFolder, folder)

        // A phone-made session matches one made by terminal `claude-tmux new` in the same folder.
        try await pty(client, cols: 80, rows: 24) { output, writer in
            let terminal = "cd " + q(folder) + " && PATH=" + q(bin) + ":\"$PATH\" " + q(script) + " new terminal-made; exit\n"
            try await writer.write(ByteBuffer(string: terminal))
            try await eventually(client, command: tmux + " display-message -p -t '=terminal-made:' '#{pane_start_command}|#{pane_current_path}|#{window_panes}'",
                                 equals: "claude|" + folder + "|1")
            try await writer.write(ByteBuffer(bytes: [2, 100]))  // detach, leaving it running
            for try await _ in output {}
        }
        for option in ["default-command", "default-shell", "status"] {
            let a = try await run(tmux + " show-options -v -t " + q(session.id) + " " + option + " 2>/dev/null; true")
            let b = try await run(tmux + " show-options -v -t '=terminal-made' " + option + " 2>/dev/null; true")
            XCTAssertEqual(a, b, option)
        }

        // Script errors come back verbatim, and nothing is created.
        let duplicate = await workspace.createSession(name: "phone-made", folder: folder)
        XCTAssertEqual(duplicate, "claude-tmux: session 'phone-made' already exists")
        let missing = await workspace.createSession(name: "no-folder", folder: "~/definitely missing folder")
        XCTAssertEqual(missing, "claude-tmux: folder '~/definitely missing folder' does not exist")
        let noClaudeWorkspace = SessionWorkspace(connection: control, tmuxCommand: tmux,
            claudeTmux: ClaudeTmux(scriptPath: noClaude, pathPrefix: "/usr/bin"))
        let noClaudeResult = await noClaudeWorkspace.createSession(name: "no-claude", folder: folder)
        XCTAssertEqual(noClaudeResult, "claude-tmux: claude CLI not found on PATH")
        let absent = SessionWorkspace(connection: control, tmuxCommand: tmux,
            claudeTmux: ClaudeTmux(scriptPath: projects + "/not-installed.sh", pathPrefix: bin))
        let absentResult = await absent.createSession(name: "absent", folder: folder)
        XCTAssertTrue(absentResult?.contains("install-claude-tmux.sh") == true, absentResult ?? "nil")
        let observed3 = try await run(tmux + " list-sessions -F '#{session_name}' | sort | tr '\\n' ' '")
        XCTAssertEqual(observed3, "keepalive phone-made terminal-made")

        // Rename the real tmux session in place: the open tab stays attached,
        // keeps its draft and follows the new name (tmux is the source of truth).
        tab.draft = "Draft kept across a rename"
        let renamed = await workspace.renameSession(session, to: "phone-renamed")
        XCTAssertNil(renamed)
        XCTAssertEqual(tab.name, "phone-renamed")
        XCTAssertTrue(tab.transport.connected, "still attached")
        XCTAssertEqual(tab.draft, "Draft kept across a rename")
        XCTAssertEqual(workspace.sessions.first { $0.id == session.id }?.name, "phone-renamed")
        let renamedState = try await run(tmux + " display-message -p -t " + q(session.id) + " '#{session_name}|#{pane_start_command}|#{session_attached}'")
        XCTAssertEqual(renamedState, "phone-renamed|claude|1", "same session, claude running, client attached")
        // A taken name is refused and nothing changes.
        let taken = await workspace.renameSession(tab.session, to: "terminal-made")
        XCTAssertEqual(taken, "“terminal-made” is already a session on \(workspace.hostLabel). Choose another name.")
        XCTAssertEqual(tab.name, "phone-renamed")
        // Renamed elsewhere since the listing (a stale name): still found by id.
        _ = try await run(tmux + " rename-session -t " + q(session.id) + " renamed-elsewhere")
        let back = await workspace.renameSession(tab.session, to: "phone-made")
        XCTAssertNil(back)
        XCTAssertEqual(tab.name, "phone-made")
        let renamedBack = try await run(tmux + " display-message -p -t " + q(session.id) + " '#{session_name}'")
        XCTAssertEqual(renamedBack, "phone-made")
        // A host without claude-tmux says how to install it.
        let absentRename = await absent.renameSession(tab.session, to: "anything")
        XCTAssertTrue(absentRename?.contains("install-claude-tmux.sh") == true, absentRename ?? "nil")
        tab.draft = ""

        // A session replaced after listing is refused, and keeps running.
        await workspace.refresh()
        let stale = try XCTUnwrap(workspace.sessions.first { $0.name == "terminal-made" })
        _ = try await run(tmux + " kill-session -t " + q(stale.id) + " && " + tmux + " new-session -d -s terminal-made /bin/cat")
        await workspace.endSession(stale)
        XCTAssertEqual(workspace.error, "“terminal-made” was replaced by a newer session with the same name, so it was not ended. Review the refreshed list before trying again.")
        let observed4 = try await run(tmux + " has-session -t '=terminal-made' && echo alive")
        XCTAssertEqual(observed4, "alive")
        XCTAssertFalse(workspace.sessions.contains { $0.id == stale.id && $0.instance == stale.instance })

        // Ending any tmux session (an unusual name, not made by claude-tmux) works.
        let unusual = "alpha $(touch pwned2) 你好"
        _ = try await run(tmux + " new-session -d -s " + q(unusual) + " /bin/cat")
        await workspace.refresh()
        await workspace.endSession(try XCTUnwrap(workspace.sessions.first { $0.name == unusual }))
        XCTAssertNil(workspace.error)
        XCTAssertFalse(workspace.sessions.contains { $0.name == unusual })
        let observed5 = try await run("test -e " + q(projects + "/pwned2") + " && echo yes || echo no")
        XCTAssertEqual(observed5, "no")

        // Ending the open tab's session: the tab stays, marked missing, with its draft.
        tab.draft = "Unsent draft survives ending"
        await workspace.endSession(session)
        XCTAssertNil(workspace.error)
        let observed6 = try await run(tmux + " has-session -t " + q(session.id) + " 2>/dev/null && echo alive || echo gone")
        XCTAssertEqual(observed6, "gone")
        XCTAssertFalse(workspace.sessions.contains { $0.id == session.id })
        XCTAssertTrue(workspace.tabs.contains { $0 === tab })
        XCTAssertFalse(tab.transport.connected)
        XCTAssertEqual(tab.transport.status, "Session no longer exists")
        XCTAssertEqual(tab.draft, "Unsent draft survives ending")
        // Ending it again reports it already ended rather than touching anything else.
        await workspace.endSession(session)
        XCTAssertEqual(workspace.error, "“phone-made” had already ended.")
        _ = try await run(tmux + " kill-server")
    }
}

/// A recording that never touches the microphone: the fixture API accepts exactly these bytes.
@MainActor
private final class SyntheticRecording: VoiceRecording {
    func start(finished: @escaping (Bool) -> Void) throws {}
    func stop() throws -> Data { Data("synthetic-recording".utf8) }
    func discard() {}
}

extension SSHIntegrationTests {
    /// Dictation from a tab on one host is transcribed by the dictation host's
    /// loopback API, over its live connection or a pinned one opened on demand.
    @MainActor
    func testDictationFromAnotherHostUsesTheDictationHost() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/") else { throw XCTSkip("Disposable fixture required") }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let macPort = f.macPort, let archPort = f.archPort, let archTmux = f.archTmux, let archSocket = f.archTmuxSocket else {
            throw XCTSkip("Fixture lacks the two-host fields")
        }
        let name = "com.chadmux.dictation-host." + UUID().uuidString
        let secrets = SecretStore(service: name), prefs = UserDefaults(suiteName: name)!
        let mac = MacConnection(host: "127.0.0.1", port: macPort, username: f.username)
        let arch = MacConnection(host: "127.0.0.1", port: archPort, username: f.username)
        try secrets.write(try Curve25519.Signing.PrivateKey(sshEd25519: f.privateKey).rawRepresentation, account: "device-ed25519")
        let pin = Data(String(openSSHPublicKey: try NIOSSHPublicKey(openSSHPublicKey: f.hostKey)).utf8)
        try secrets.write(pin, account: mac.trustID); try secrets.write(pin, account: arch.trustID)
        // Only the dictation host (Mac) has a token: Arch's would be ignored anyway.
        try secrets.write(Data("fixture-transcription-token".utf8), account: mac.apiTokenID)
        defer {
            prefs.removePersistentDomain(forName: name)
            for account in ["device-ed25519", mac.trustID, arch.trustID, mac.apiTokenID] { try? secrets.remove(account) }
        }
        let q = SSHPrimitives.shellQuote
        let archCommand = "/usr/bin/env LC_ALL=en_US.UTF-8 " + q(archTmux) + " -u -f /dev/null -S " + q(archSocket)
        let voice = VoiceCoordinator(permission: { true }, makeRecording: { SyntheticRecording() })
        let archWorkspace = SessionWorkspace(connection: MacTransport(preferences: prefs, secrets: secrets, profile: arch), tmuxCommand: archCommand, voice: voice)
        let macWorkspace = SessionWorkspace(connection: MacTransport(preferences: prefs, secrets: secrets, profile: mac), voice: voice)
        let hosts = HostsModel(fixture: [("Arch", archWorkspace), ("Mac", macWorkspace)])
        hosts.dictationHostID = hosts.hosts[1].id
        hosts.dictationPort = f.apiPort
        defer { archWorkspace.disconnect(); macWorkspace.disconnect() }

        // A live tab on Arch.
        archWorkspace.connection.connect(openShell: false)
        for _ in 0..<150 where !archWorkspace.connection.connected { try await Task.sleep(nanoseconds: 100_000_000) }
        let archClient = try XCTUnwrap(archWorkspace.connection.client, archWorkspace.connection.status)
        _ = try await archClient.executeCommand(archCommand + " new-session -d -s dictate " + q("printf 'READY\\n\\033[?25l'; exec sleep 600"), maxResponseSize: 1024)
        await archWorkspace.refresh()
        hosts.becameActive()
        hosts.select(try XCTUnwrap(archWorkspace.sessions.first { $0.name == "dictate" }), on: hosts.hosts[0].id)
        await archWorkspace.waitForResume()
        let tab = try XCTUnwrap(archWorkspace.selected)
        XCTAssertTrue(tab.transport.connected, archWorkspace.error ?? tab.transport.status)

        func dictate() async throws {
            voice.start(tab: tab)
            for _ in 0..<50 where voice.phase != .recording { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertEqual(voice.phase, .recording, tab.dictationStatus ?? "did not start")
            voice.stop()
            for _ in 0..<300 where voice.active { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        // 1. The Mac isn't connected: a pinned connection is opened for this request only.
        XCTAssertFalse(macWorkspace.connection.connected)
        try await dictate()
        XCTAssertEqual(tab.draft, "Forwarded safely over SSH", tab.dictationStatus ?? "")
        XCTAssertEqual(tab.dictationStatus, "Dictation added. Edit it before sending.")
        XCTAssertFalse(macWorkspace.connection.connected, "the on-demand connection doesn't become the host's connection")

        // 2. With the Mac connected, its live connection is used.
        macWorkspace.connection.connect(openShell: false)
        for _ in 0..<150 where !macWorkspace.connection.connected { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(macWorkspace.connection.connected)
        try await dictate()
        XCTAssertEqual(tab.draft, "Forwarded safely over SSH Forwarded safely over SSH")

        // 3. A rejected token changes nothing in the draft.
        try secrets.write(Data("wrong-token-0123456789".utf8), account: mac.apiTokenID)
        try await dictate()
        XCTAssertEqual(tab.draft, "Forwarded safely over SSH Forwarded safely over SSH")
        XCTAssertNotEqual(tab.dictationStatus, "Dictation added. Edit it before sending.")
        _ = try? await archClient.executeCommand(archCommand + " kill-server", maxResponseSize: 1024)
    }
}
