import XCTest
import NIO
@testable import Chadmux

@MainActor
private final class SilentRecording: VoiceRecording {
    var starts = 0, stops = 0, discards = 0
    func start(finished: @escaping (Bool) -> Void) throws { starts += 1 }
    func stop() throws -> Data { stops += 1; return Data([1, 2, 3]) }
    func discard() { discards += 1 }
}

/// Mac dictation: the transcript is pasted into the terminal as one bracketed
/// paste with no Enter. Recording, transcription and terminal writes are injected.
@MainActor
final class MacDictationTests: XCTestCase {
    private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    func testPasteBytesAreOneBracketedLineWithNoEnterOrControlCharacters() {
        XCTAssertEqual(text(TerminalDictation.pasteBytes("fix the failing test", bracketed: true)),
                       "\u{1b}[200~fix the failing test \u{1b}[201~")
        XCTAssertEqual(text(TerminalDictation.pasteBytes("fix the failing test", bracketed: false)), "fix the failing test ")
        // Newlines and tabs become single spaces; the ends are trimmed.
        XCTAssertEqual(text(TerminalDictation.pasteBytes("  first line\r\nsecond\tthird\n\n", bracketed: false)), "first line second third ")
        // ESC (so no escape sequence or early end-of-paste), BEL, DEL and C1 controls are dropped.
        let hostile = "a\u{1b}[201~\rrm -rf\u{07}\u{7f}\u{9b}31m\u{85}b\u{2028}c"
        XCTAssertEqual(text(TerminalDictation.pasteBytes(hostile, bracketed: false)), "a[201~ rm -rf31m b c ")
        let bracketed = TerminalDictation.pasteBytes(hostile, bracketed: true)
        XCTAssertFalse(bracketed.contains(10)); XCTAssertFalse(bracketed.contains(13))
        XCTAssertEqual(bracketed.filter { $0 == 0x1b }.count, 2, "only the paste markers' own ESCs")
        XCTAssertTrue(bracketed.allSatisfy { $0 >= 0x20 || $0 == 0x1b })
        // Unicode survives; nothing printable left means nothing to paste.
        XCTAssertEqual(text(TerminalDictation.pasteBytes("café 你好", bracketed: false)), "café 你好 ")
        XCTAssertEqual(TerminalDictation.pasteBytes(" \n\u{1b}\u{07} ", bracketed: true), [])
    }

    // MARK: VoiceCoordinator with the Mac's terminal delivery

    private final class Terminal {
        var written: [[UInt8]] = []
        var ready = true
        var bracketed = true
        var fails = false
    }
    private struct WriteFailed: Error {}
    private func tab() -> SessionTab {
        SessionTab(session: RemoteSession(id: "$1", name: "work"), profile: MacConnection(),
                   secrets: SecretStore(service: "com.chadmux.mac-dictation-tests." + UUID().uuidString))
    }
    private func voice(_ terminal: Terminal, recorder: SilentRecording, permission: Bool = true) -> VoiceCoordinator {
        let voice = VoiceCoordinator(permission: { permission }, makeRecording: { recorder })
        voice.deliver = { _, transcript in
            try await TerminalDictation.deliver(transcript, ready: { terminal.ready }, bracketed: { terminal.bracketed }) { bytes in
                if terminal.fails { throw WriteFailed() }
                terminal.written.append(bytes)
            }
        }
        return voice
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Dictation state did not settle")
    }
    private func dictate(_ voice: VoiceCoordinator, _ tab: SessionTab, transcript: @escaping (Data) async throws -> String) async throws {
        voice.start(tab: tab, transcribe: transcript)
        try await wait { voice.phase == .recording }
        voice.stop()
        try await wait { !voice.active }
    }

    func testTranscriptIsPastedIntoTheTerminalWithoutEnter() async throws {
        let terminal = Terminal(), recorder = SilentRecording(), tab = tab()
        let voice = voice(terminal, recorder: recorder)
        try await dictate(voice, tab) { audio in
            XCTAssertEqual(audio, Data([1, 2, 3]))
            return "Refactor the parser\nand add tests\u{1b}[2J"
        }
        XCTAssertEqual(terminal.written.map(text), ["\u{1b}[200~Refactor the parser and add tests[2J \u{1b}[201~"])
        XCTAssertEqual(tab.dictationStatus, TerminalDictation.pasted)
        XCTAssertEqual(tab.draft, "", "the Mac has no draft: nothing is inserted there")
        XCTAssertNil(tab.pendingTranscript)
        XCTAssertEqual(recorder.starts, 1); XCTAssertEqual(recorder.stops, 1)
        // Without bracketed paste mode, the same line is typed, still with no Enter.
        terminal.bracketed = false
        try await dictate(voice, tab) { _ in "again" }
        XCTAssertEqual(terminal.written.last.map(text), "again ")
    }

    func testCancelPastesNothing() async throws {
        let terminal = Terminal(), recorder = SilentRecording(), tab = tab()
        let voice = voice(terminal, recorder: recorder)
        // While recording.
        voice.start(tab: tab) { _ in XCTFail("cancelled audio is never transcribed"); return "wrong" }
        try await wait { voice.phase == .recording }
        voice.cancel(message: TerminalDictation.cancelled)
        XCTAssertFalse(voice.active)
        XCTAssertEqual(tab.dictationStatus, TerminalDictation.cancelled)
        XCTAssertGreaterThan(recorder.discards, 0)
        // While transcribing: a late reply is dropped.
        let reply = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)
        voice.start(tab: tab) { _ in try await reply.futureResult.get() }
        try await wait { voice.phase == .recording }
        voice.stop()
        XCTAssertEqual(voice.phase, .transcribing)
        voice.cancel(message: TerminalDictation.cancelled)
        reply.succeed("too late")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(terminal.written, [])
        XCTAssertEqual(tab.dictationStatus, TerminalDictation.cancelled)
        XCTAssertFalse(TerminalDictation.isError(TerminalDictation.cancelled))
    }

    func testFailuresPasteNothingAndSaySo() async throws {
        let terminal = Terminal(), recorder = SilentRecording(), tab = tab()
        let voice = voice(terminal, recorder: recorder)
        try await dictate(voice, tab) { _ in throw LoopbackAPI.Rejected(status: 500) }
        XCTAssertEqual(tab.dictationStatus, "Transcription failed or timed out. Check the dictation host, SSH and the companion server, then record again. Nothing was pasted.")
        try await dictate(voice, tab) { _ in throw LoopbackAPI.Rejected(status: 503) }
        XCTAssertTrue(tab.dictationStatus?.hasPrefix("Dictation is unavailable.") == true)
        try await dictate(voice, tab) { _ in " \n " }
        XCTAssertTrue(tab.dictationStatus?.hasPrefix("No speech detected.") == true)
        try await dictate(voice, tab) { _ in "\u{1b}\u{07}" }
        XCTAssertEqual(tab.dictationStatus, "No speech detected. Nothing was pasted.")
        terminal.ready = false
        try await dictate(voice, tab) { _ in "hello" }
        XCTAssertEqual(tab.dictationStatus, TerminalDictation.disconnected)
        terminal.ready = true; terminal.fails = true
        try await dictate(voice, tab) { _ in "hello" }
        XCTAssertEqual(tab.dictationStatus, TerminalDictation.interrupted)
        XCTAssertEqual(terminal.written, [])
        XCTAssertTrue(TerminalDictation.isError(TerminalDictation.interrupted))
        XCTAssertFalse(TerminalDictation.isError(TerminalDictation.pasted))
    }

    func testDeniedMicrophoneAndClosedTabPasteNothing() async throws {
        let terminal = Terminal(), recorder = SilentRecording(), tab = tab()
        let denied = voice(terminal, recorder: recorder, permission: false)
        denied.start(tab: tab) { _ in "wrong" }
        try await wait { !denied.active }
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(tab.dictationStatus, "Microphone access is off. Allow Chadmux in System Settings › Privacy & Security › Microphone, then try again.")
        // The origin tab closing while transcribing drops the result.
        let voice = voice(terminal, recorder: recorder)
        let reply = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)
        voice.start(tab: tab) { _ in try await reply.futureResult.get() }
        try await wait { voice.phase == .recording }
        voice.stop()
        tab.closed = true
        reply.succeed("after close")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(terminal.written, [])
    }

    func testTheMicNeedsAConnectedSessionAndDictationRoutesThroughTheHostsModel() async throws {
        let scope = "com.chadmux.mac-dictation-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: scope)!
        addTeardownBlock { preferences.removePersistentDomain(forName: scope) }
        let model = HostsModel(preferences: preferences, secrets: SecretStore(service: scope), recovery: nil,
                               media: MediaStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(scope)))
        let actions = MacWindowActions(model: model, preferences: preferences)
        XCTAssertNotNil(model.voice.deliver, "the Mac window pastes transcripts into the terminal")
        let host = HostProfile(label: "server", connection: MacConnection(host: "server.example", port: 22, username: "user"))
        try model.add(host)
        let workspace = try XCTUnwrap(model.workspace(for: host.id))
        let offline = tab()
        actions.toggleDictation(MacTabs.Entry(host: host, workspace: workspace, tab: offline))
        XCTAssertFalse(model.voice.active)
        XCTAssertEqual(offline.dictationStatus, "Connect to server before dictating.")
    }
}
