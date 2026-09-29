import XCTest
import NIO
@testable import Chadmux

final class ComposerTests: XCTestCase {
    func testAttachReadinessRejectsEchoedOrIncompleteShellAnnouncement() {
        XCTAssertNil(TmuxSessions.announcedPID(in: "printf '\\036marker:%s\\037' \"$$\"", marker: "marker"))
        XCTAssertNil(TmuxSessions.announcedPID(in: "\u{1e}marker:123", marker: "marker"))
        XCTAssertNil(TmuxSessions.announcedPID(in: "\u{1e}other:123\u{1f}", marker: "marker"))
        XCTAssertEqual(TmuxSessions.announcedPID(in: "noise\u{1e}marker:123\u{1f}more", marker: "marker"), "123")
    }

    func testMultilineLiteralPasteAndControlRefusal() throws {
        let text = "first line\r\n$(not-a-command) 你好\nlast line"
        XCTAssertEqual(String(decoding: try ComposedMessage.bytes(text), as: UTF8.self),
                       "\u{1b}[200~first line\n$(not-a-command) 你好\nlast line\u{1b}[201~\r")
        for invalid in ["", " \n", "before\u{1b}[201~bad", "\u{03}", String(repeating: "x", count: 65_537)] {
            XCTAssertThrowsError(try ComposedMessage.bytes(invalid))
        }
        XCTAssertEqual(TerminalControl.enter.bytes(applicationCursor: false), [13])
        XCTAssertEqual(TerminalControl.interrupt.bytes(applicationCursor: false), [3])
        XCTAssertEqual(TerminalControl.up.bytes(applicationCursor: true), [27,79,65])
        XCTAssertEqual(TerminalControl.up.bytes(applicationCursor: false), [27,91,65])
    }

    @MainActor
    func testHeldSendStaysWithOriginRejectsDuplicateAndPreservesNewEdits() async throws {
        let service = "com.chadmux.composer-tests." + UUID().uuidString
        let secrets = SecretStore(service: service)
        defer { try? secrets.remove("device-ed25519") }
        let a = SessionTab(session: RemoteSession(id:"$0",name:"A"),profile:MacConnection(),secrets:secrets)
        let b = SessionTab(session: RemoteSession(id:"$1",name:"B"),profile:MacConnection(),secrets:secrets)
        let preferences = UserDefaults(suiteName: service)!
        defer { preferences.removePersistentDomain(forName: service) }
        let workspace = SessionWorkspace(connection: MacTransport(preferences: preferences, secrets: secrets))
        workspace.tabs = [a,b]; workspace.selectedID = a.id
        a.draft = "First\nMessage"; b.draft = "Other draft"
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let started = loop.makePromise(of:Void.self), release = loop.makePromise(of:Void.self)
        var writes: [[UInt8]] = []
        let sending = Task { await a.submit(pasteEnabled:true) { bytes in
            writes.append(bytes); started.succeed(()); try await release.futureResult.get()
        } }
        try await started.futureResult.get()
        workspace.selectedID = b.id
        await a.submit(pasteEnabled:true) { writes.append($0) }
        XCTAssertTrue(a.sending)
        a.draft = "New edits made while sending"
        release.succeed(())
        await sending.value
        XCTAssertEqual(writes.count,1)
        XCTAssertEqual(writes.first,try ComposedMessage.bytes("First\nMessage"))
        XCTAssertEqual(a.draft,"New edits made while sending")
        XCTAssertEqual(b.draft,"Other draft")
        XCTAssertNil(b.submissionMessage)
        XCTAssertFalse(a.sending)
    }

    @MainActor
    func testFailureRequiresAcknowledgementAndDoesNotReplay() async throws {
        let secrets = SecretStore(service:"com.chadmux.composer-tests." + UUID().uuidString)
        defer { try? secrets.remove("device-ed25519") }
        let tab = SessionTab(session:RemoteSession(id:"$0",name:"Fixture"),profile:MacConnection(),secrets:secrets)
        tab.draft = "Keep my draft"
        var writes = 0
        await tab.submit(pasteEnabled:false) { _ in writes += 1 }
        XCTAssertEqual(writes,0)
        XCTAssertEqual(tab.draft,"Keep my draft")
        await tab.submit(pasteEnabled:true) { _ in writes += 1; throw MacTransport.NotConnected() }
        XCTAssertTrue(tab.deliveryUncertain)
        XCTAssertEqual(tab.draft,"Keep my draft")
        await tab.submit(pasteEnabled:true) { _ in writes += 1 }
        XCTAssertEqual(writes,1)
        tab.deliveryUncertain = false // explicit user acknowledgement
        await tab.submit(pasteEnabled:true) { _ in writes += 1 }
        XCTAssertEqual(writes,2)
        XCTAssertEqual(tab.draft,"")
        XCTAssertEqual(tab.submissionMessage,"Sent to terminal. Check Claude for receipt.")
    }
}
