import XCTest
import NIO
import AVFAudio
@testable import Chadmux

@MainActor
private final class FakeRecording: VoiceRecording {
    var starts = 0, stops = 0, discards = 0
    var startError: Error?
    var finished: ((Bool) -> Void)?
    func start(finished: @escaping (Bool) -> Void) throws { starts += 1; if let startError { throw startError }; self.finished = finished }
    func stop() throws -> Data { stops += 1; return Data([1,2,3]) }
    func discard() { discards += 1 }
}

final class VoiceTests: XCTestCase {
    @MainActor
    private func tab(_ name: String = "Origin") -> SessionTab {
        SessionTab(session: RemoteSession(id: name, name: name), profile: MacConnection(), secrets: SecretStore(service: "com.chadmux.voice-tests." + UUID().uuidString))
    }
    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Dictation state did not settle")
    }
    @MainActor
    func testResultBelongsToOriginAndNeverSubmits() async throws {
        let original = tab(), other = tab("Other"), recorder = FakeRecording()
        let voice = VoiceCoordinator(permission: { true }, makeRecording: { recorder })
        original.draft = "Please"; other.draft = "Other draft"
        let reply = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)
        var requests = 0
        voice.start(tab: original) { data in requests += 1; XCTAssertEqual(data, Data([1,2,3])); return try await reply.futureResult.get() }
        try await wait { voice.phase == .recording }
        voice.start(tab: other) { _ in XCTFail("Duplicate recording"); return "wrong" }
        voice.stop(); voice.stop()
        try await wait { requests == 1 }
        XCTAssertTrue(voice.origin === original)
        reply.succeed("fix the test")
        try await wait { !voice.active }
        XCTAssertEqual(original.draft, "Please fix the test")
        XCTAssertEqual(other.draft, "Other draft")
        XCTAssertFalse(original.sending); XCTAssertNil(original.submissionMessage)
        XCTAssertEqual(recorder.starts, 1); XCTAssertEqual(recorder.stops, 1)
    }
    @MainActor
    func testConcurrentEditsBecomePendingTranscript() async throws {
        let original = tab(), recorder = FakeRecording()
        let voice = VoiceCoordinator(permission: { true }, makeRecording: { recorder })
        let reply = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)
        original.draft = "Before"
        voice.start(tab: original) { _ in try await reply.futureResult.get() }
        try await wait { voice.phase == .recording }
        voice.stop(); original.draft = "My new edit"
        reply.succeed("A transcript")
        try await wait { !voice.active }
        XCTAssertEqual(original.draft, "My new edit")
        XCTAssertEqual(original.pendingTranscript, "A transcript")
        voice.start(tab: original) { _ in "must not start" }
        XCTAssertFalse(voice.active)
        XCTAssertEqual(VoiceCoordinator.appending("A transcript", to: original.draft), "My new edit A transcript")
    }
    @MainActor
    func testCancelDuringPermissionNeverOpensMicrophone() async throws {
        let original = tab(), recorder = FakeRecording()
        let permission = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Bool.self)
        let voice = VoiceCoordinator(permission: { (try? await permission.futureResult.get()) ?? false }, makeRecording: { recorder })
        voice.start(tab: original) { _ in XCTFail("Cancelled request"); return "wrong" }
        voice.cancel(); permission.succeed(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.starts, 0); XCTAssertFalse(voice.active)
    }
    @MainActor
    func testCancelAndLateReplyCannotTouchNewRecording() async throws {
        let original = tab(), other = tab("Other"), recorder = FakeRecording()
        let voice = VoiceCoordinator(permission: { true }, makeRecording: { recorder })
        let reply = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)
        original.draft = "Keep"
        voice.start(tab: original) { _ in try await reply.futureResult.get() }
        try await wait { voice.phase == .recording }; voice.stop()
        try await Task.sleep(for: .milliseconds(20))
        voice.cancel()
        voice.start(tab: other) { _ in "new" }
        try await wait { voice.phase == .recording }
        reply.succeed("stale")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(original.draft, "Keep"); XCTAssertNil(original.pendingTranscript)
        XCTAssertTrue(voice.origin === other); XCTAssertEqual(voice.phase, .recording)
        voice.cancel(); XCTAssertGreaterThan(recorder.discards, 0)
    }
    @MainActor
    func testDeniedSilenceAndBackendFailureRetainDraft() async throws {
        let original = tab(), recorder = FakeRecording()
        original.draft = "Keep"
        let denied = VoiceCoordinator(permission: { false }, makeRecording: { recorder })
        denied.start(tab: original) { _ in "wrong" }
        try await wait { !denied.active }; XCTAssertEqual(recorder.starts, 0)
        XCTAssertTrue(original.dictationStatus?.contains("Settings") == true)
        let voice = VoiceCoordinator(permission: { true }, makeRecording: { recorder })
        voice.start(tab: original) { _ in " \n" }
        try await wait { voice.phase == .recording }; voice.stop()
        try await wait { !voice.active }
        XCTAssertEqual(original.draft, "Keep"); XCTAssertTrue(original.dictationStatus?.contains("No speech") == true)
        voice.start(tab: original) { _ in throw LoopbackAPI.Rejected(status: 429) }
        try await wait { voice.phase == .recording }; voice.stop()
        try await wait { !voice.active }
        XCTAssertEqual(original.draft, "Keep"); XCTAssertTrue(original.dictationStatus?.contains("already transcribing") == true)
    }
    @MainActor
    func testNativeAACEncoderAcceptsProductionSettingsAndDecodesSyntheticAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.m4a")
        // Native encoder, no AVAudioSession activation or microphone permission.
        // This fails with the old 16 kHz / 64 kbit/s production settings.
        do {
            let file = try AVAudioFile(forWriting: url, settings: MicrophoneRecording.audioSettings)
            let count: AVAudioFrameCount = 8_000
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
            buffer.frameLength = count
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for i in 0..<Int(count) { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / 16_000) * 0.1) }
            try file.write(from: buffer)
        }
        let decoded = try AVAudioFile(forReading: url)
        XCTAssertEqual(decoded.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(decoded.fileFormat.channelCount, 1)
        XCTAssertGreaterThanOrEqual(decoded.length, 8_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 8_000))
        try decoded.read(into: buffer)
        XCTAssertGreaterThan(buffer.frameLength, 0)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertTrue((0..<Int(buffer.frameLength)).contains { abs(samples[$0]) > 0.01 })
    }

    @MainActor
    func testStartupFailurePreservesDraftCleansRecorderAndExposesSafeStage() async throws {
        let original = tab(), recorder = FakeRecording()
        original.draft = "Keep my edits"
        recorder.startError = MicrophoneRecording.StartupFailure(stage: .encoder, code: 560226676)
        let voice = VoiceCoordinator(permission: { true }, makeRecording: { recorder })
        voice.start(tab: original) { _ in XCTFail("Failed startup must not upload"); return "wrong" }
        try await wait { !voice.active }
        XCTAssertEqual(original.draft, "Keep my edits")
        XCTAssertNil(voice.origin)
        XCTAssertEqual(recorder.discards, 1)
        XCTAssertEqual(recorder.stops, 0)
        XCTAssertTrue(original.dictationStatus?.contains("audio encoder") == true)
        XCTAssertTrue(original.dictationStatus?.contains("560226676") == true)
        XCTAssertFalse(original.dictationStatus?.contains("Close other audio apps") == true)
    }
}
