import SwiftUI
import AVFAudio

@MainActor
protocol VoiceRecording: AnyObject {
    func start(finished: @escaping (Bool) -> Void) throws
    func stop() throws -> Data
    func discard()
}

@MainActor
final class MicrophoneRecording: NSObject, VoiceRecording, AVAudioRecorderDelegate {
    // Native Apple AAC rejects 64 kbit/s at 16 kHz mono on tested hardware.
    static let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
    enum StartupStage: String { case session = "audio session", activation = "microphone activation", storage = "temporary audio storage", encoder = "audio encoder", preparation = "recorder preparation", protection = "audio file protection", recording = "recording" }
    struct StartupFailure: Error {
        let stage: StartupStage
        let code: Int?
        var message: String {
            let detail = code.map { " (code \($0))" } ?? ""
            return "Could not start \(stage.rawValue)\(detail). " + (stage == .storage || stage == .protection
                ? "Unlock the phone and check free space, then try again."
                : "Try recording again; if it persists, report this message.")
        }
    }
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var finished: ((Bool) -> Void)?
    func start(finished: @escaping (Bool) -> Void) throws {
        self.finished = finished
        var stage = StartupStage.session
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            stage = .activation
            try session.setActive(true)
            #endif
            stage = .storage
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChadmuxVoice", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            let file = directory.appendingPathComponent(UUID().uuidString + ".m4a")
            url = file
            stage = .encoder
            let recorder = try AVAudioRecorder(url: file, settings: Self.audioSettings)
            self.recorder = recorder; recorder.delegate = self
            stage = .preparation
            guard recorder.prepareToRecord() else { throw StartupFailure(stage: stage, code: nil) }
            stage = .protection
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            var resource = URLResourceValues(); resource.isExcludedFromBackup = true
            var protectedFile = file; try protectedFile.setResourceValues(resource)
            stage = .recording
            guard recorder.record(forDuration: 120) else { throw StartupFailure(stage: stage, code: nil) }
        } catch {
            // Do not expose localized descriptions/userInfo: filesystem errors can
            // include private paths. Preserve only our fixed stage and OS number.
            let failure = (error as? StartupFailure) ?? StartupFailure(stage: stage, code: (error as NSError).code)
            discard(); throw failure
        }
    }
    func stop() throws -> Data {
        recorder?.delegate = nil; recorder?.stop()
        guard let url else { throw LoopbackAPI.Unavailable() }
        defer { discard() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 12 * 1024 * 1024 else { throw LoopbackAPI.Unavailable() }
        return try Data(contentsOf: url)
    }
    func discard() {
        recorder?.delegate = nil; recorder?.stop(); recorder = nil; finished = nil
        if let url { try? FileManager.default.removeItem(at: url) }; url = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finished?(flag) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in self?.finished?(false) }
    }
}

@MainActor
final class VoiceCoordinator: ObservableObject {
    enum Phase { case idle, permission, recording, transcribing }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var originName = ""
    private(set) var origin: SessionTab?
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var recording: VoiceRecording?
    private var transcribe: ((Data) async throws -> String)?
    private var draftSnapshot = ""
    let permission: () async -> Bool
    let makeRecording: @MainActor () -> VoiceRecording
    init(permission: @escaping () async -> Bool = {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }, makeRecording: @escaping @MainActor () -> VoiceRecording = { MicrophoneRecording() }) {
        self.permission = permission; self.makeRecording = makeRecording
    }
    var active: Bool { phase != .idle }

    enum Route {
        case ready((Data) async throws -> String)
        case unavailable(String)
    }
    /// Where a tab's dictation goes. Set by HostsModel to the designated
    /// dictation host, whichever host the tab itself is on.
    var route: ((SessionTab) -> Route)?
    /// Where a finished transcript goes instead of the origin's draft. The Mac,
    /// which has no input bar, pastes it into the terminal. Returns the status
    /// to show; throwing `DeliveryFailed` shows its message. Unset (iOS), the
    /// transcript is added to the draft as before.
    var deliver: ((SessionTab, String) async throws -> String)?
    struct DeliveryFailed: Error { let message: String }
    /// What a failure leaves behind, in the words of where the text would go.
    private var unchanged: String { deliver == nil ? "Your draft is unchanged" : "Nothing was pasted" }

    func start(tab: SessionTab) {
        if let route {
            switch route(tab) {
            case .ready(let transcribe): start(tab: tab, transcribe: transcribe)
            case .unavailable(let message): tab.dictationStatus = message
            }
            return
        }
        guard let client = tab.transport.client, tab.transport.connected else {
            tab.dictationStatus = "Connect to the dictation host before recording."; return
        }
        do {
            guard let data = try tab.transport.secrets.read(tab.transport.profile.apiTokenID),
                  let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                tab.dictationStatus = "Add the transcription token for the dictation host in Connection settings first."; return
            }
            start(tab: tab) { audio in
                try await LoopbackAPI.transcribe(client: client, recording: audio, token: token).text
            }
        } catch { tab.dictationStatus = "Unlock your phone to read the transcription token, then try again." }
    }

    // Injection exercises ownership and cancellation without recording ambient audio.
    func start(tab: SessionTab, transcribe: @escaping (Data) async throws -> String) {
        guard !active, !tab.closed, !tab.sending, tab.pendingTranscript == nil else { return }
        let current = UUID(); generation = current
        origin = tab; originName = tab.name; draftSnapshot = tab.draft
        self.transcribe = transcribe; phase = .permission; tab.dictationStatus = nil
        operation = Task {
            let granted = await permission()
            guard generation == current, !Task.isCancelled, !tab.closed else { return }
            guard granted else {
                #if os(macOS)
                finish(message: "Microphone access is off. Allow Chadmux in System Settings › Privacy & Security › Microphone, then try again."); return
                #else
                finish(message: "Microphone access is off. Enable it for Chadmux in iPhone Settings to dictate."); return
                #endif
            }
            do {
                let recorder = makeRecording(); recording = recorder
                try recorder.start { [weak self] success in
                    guard let self, self.generation == current, self.phase == .recording else { return }
                    if success { self.stop() } else { self.cancel(message: "Recording failed. \(self.unchanged); try again.") }
                }
                phase = .recording
            } catch {
                finish(message: (error as? MicrophoneRecording.StartupFailure)?.message
                    ?? "Recording could not start. \(unchanged); try again and report the error if it persists.")
            }
        }
    }
    func stop() {
        guard phase == .recording, let tab = origin, let recording, let transcribe else { return }
        phase = .transcribing
        let current = generation
        let data: Data
        do { data = try recording.stop(); self.recording = nil }
        catch { finish(message: "Could not read the recording. \(unchanged); record again."); return }
        operation = Task {
            do {
                let text = try await transcribe(data).trimmingCharacters(in: .whitespacesAndNewlines)
                guard generation == current, !Task.isCancelled, !tab.closed else { return }
                guard !text.isEmpty else { finish(message: "No speech detected. Try recording again."); return }
                guard text.utf8.count <= 16_384 else { throw LoopbackAPI.Unavailable() }
                if let deliver {
                    let message = try await deliver(tab, text)
                    guard generation == current else { return }
                    finish(message: message)
                } else if tab.draft == draftSnapshot {
                    tab.draft = Self.appending(text, to: tab.draft)
                    finish(message: "Dictation added. Edit it before sending.")
                } else {
                    tab.pendingTranscript = text
                    finish(message: "Your draft changed. Review the transcript below, then insert or discard it.")
                }
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                finish(message: Self.message(for: error, pasting: deliver != nil))
            }
        }
    }
    func cancel(message: String = "Dictation cancelled. Your draft is unchanged.") {
        guard active else { return }
        generation = UUID(); operation?.cancel(); finish(message: message)
    }
    private func finish(message: String) {
        recording?.discard(); recording = nil
        if let origin, !origin.closed { origin.dictationStatus = message }
        origin = nil; transcribe = nil; operation = nil; originName = ""; phase = .idle
    }
    static func appending(_ text: String, to draft: String) -> String {
        draft + (draft.isEmpty || draft.last?.isWhitespace == true ? "" : " ") + text
    }
    static func message(for error: Error, pasting: Bool = false) -> String {
        if let error = error as? DeliveryFailed { return error.message }
        if error is LoopbackAPI.InvalidToken { return "Check the transcription token in Connection settings." }
        if let error = error as? LoopbackAPI.Rejected {
            switch error.status {
            case 401: return "Transcription token was rejected. Update it in Connection settings."
            case 429: return "The dictation host is already transcribing. Wait for it to finish, then record again."
            case 413: return "Recording is too long or large. Try a shorter recording."
            case 415, 422: return "The recording could not be decoded. Try recording again."
            case 503: return "Dictation is unavailable. Start the companion server and its resident Whisper service on the dictation host."
            default: break
            }
        }
        return "Transcription failed or timed out. Check the dictation host, SSH and the companion server, then record again. " + (pasting ? "Nothing was pasted." : "Your draft is retained.")
    }
}

struct VoiceActivity: View {
    @ObservedObject var voice: VoiceCoordinator
    var body: some View {
        if voice.active {
            HStack {
                Text((voice.phase == .recording ? "Recording (2 min max): " : voice.phase == .permission ? "Microphone permission: " : "Transcribing: ") + voice.originName).font(.caption)
                Spacer()
                if voice.phase == .recording { Button("Stop") { voice.stop() }.accessibilityIdentifier("dictation.stop") }
                Button("Cancel") { voice.cancel() }.accessibilityIdentifier("dictation.cancel")
            }.padding(8).background(.bar).accessibilityIdentifier("dictation.activity")
        }
    }
}
