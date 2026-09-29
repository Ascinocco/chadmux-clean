import SwiftUI

/// Dictation on the Mac, which has no input bar: the shared VoiceCoordinator
/// records with this Mac's microphone and transcribes on the dictation host
/// (as on the iPhone); the transcript is then pasted into the session's
/// terminal as one bracketed paste with no Enter, like a dropped image's path.
/// Only text reaches the session's host, so it works the same for every host.
enum TerminalDictation {
    static let pasted = "Dictation pasted. Edit it, then press Enter."
    static let cancelled = "Dictation cancelled. Nothing was pasted."
    static let disconnected = "The session disconnected before the text was pasted. Nothing was pasted."
    static let interrupted = "The connection dropped while pasting. Check the terminal before dictating again."
    /// Statuses that are not problems; anything else shows as an error.
    static func isError(_ status: String) -> Bool { status != pasted && status != cancelled }

    /// The transcript as one line of plain text: whitespace runs (newlines,
    /// tabs) become one space, the ends are trimmed, and every other control
    /// character (C0 including ESC, DEL, C1) is dropped, so
    /// it can never submit the prompt or carry an escape sequence.
    nonisolated static func sanitized(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var space = false
        for scalar in text.unicodeScalars {
            // Runs of whitespace (newlines, tabs, line separators) become one space.
            if scalar.properties.isWhitespace { space = !out.isEmpty; continue }
            let value = scalar.value
            if value < 0x20 || (0x7F...0x9F).contains(value) { continue }
            if space { out.append(" "); space = false }
            out.append(scalar)
        }
        return String(out)
    }

    /// The bytes that paste the transcript: bracketed when the remote asks,
    /// followed by a space so typing or dictating again continues the line,
    /// and never a newline. Empty when nothing printable is left.
    nonisolated static func pasteBytes(_ text: String, bracketed: Bool) -> [UInt8] {
        let clean = sanitized(text)
        guard !clean.isEmpty else { return [] }
        let body = Array((clean + " ").utf8)
        return bracketed ? Array("\u{1b}[200~".utf8) + body + Array("\u{1b}[201~".utf8) : body
    }

    /// Pastes a finished transcript; the status to show, or `DeliveryFailed`.
    @MainActor
    static func deliver(_ text: String, ready: () -> Bool, bracketed: () -> Bool,
                        write: ([UInt8]) async throws -> Void) async throws -> String {
        let bytes = pasteBytes(text, bracketed: bracketed())
        guard !bytes.isEmpty else { throw VoiceCoordinator.DeliveryFailed(message: "No speech detected. Nothing was pasted.") }
        guard ready() else { throw VoiceCoordinator.DeliveryFailed(message: disconnected) }
        do { try await write(bytes) } catch { throw VoiceCoordinator.DeliveryFailed(message: interrupted) }
        return pasted
    }

    /// Sends every transcript to its origin tab's terminal.
    @MainActor
    static func install(on voice: VoiceCoordinator) {
        voice.deliver = { tab, text in
            let transport = tab.transport
            return try await deliver(text, ready: { transport.connected && !tab.closed },
                                     bracketed: { transport.terminal.getTerminal().bracketedPasteMode },
                                     write: { try await transport.sendBytes($0) })
        }
    }
}

/// The mic in the terminal's bottom-right corner, beside "Live": click to
/// record, click again to transcribe and paste; × or Esc discards.
struct MacDictationControl: View {
    @ObservedObject var voice: VoiceCoordinator
    @ObservedObject var tab: SessionTab
    let toggle: () -> Void
    let cancel: () -> Void
    private var mine: Bool { voice.origin === tab }
    private var elsewhere: Bool { voice.active && !mine }

    var body: some View {
        HStack(spacing: 6) {
            if mine && voice.active {
                Button(action: cancel) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 12, height: 14)
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(Capsule().fill(MacTheme.panel)).overlay(Capsule().stroke(MacTheme.rule))
                }
                .buttonStyle(.plain).foregroundStyle(MacTheme.secondary)
                .help("Discard the recording; nothing is pasted (Esc)")
                .accessibilityLabel("Cancel dictation").accessibilityIdentifier("terminal.dictationCancel")
            }
            Button(action: toggle) { label }
                .buttonStyle(.plain)
                .foregroundStyle(recording ? MacTheme.danger : MacTheme.primary)
                .disabled(elsewhere || (mine && voice.phase != .recording))
                .help(help)
                .accessibilityLabel(accessibility)
                .accessibilityValue(mine ? phaseName : "")
                .accessibilityIdentifier("terminal.dictate")
        }
    }

    private var recording: Bool { mine && voice.phase == .recording }
    private var phaseName: String {
        switch voice.phase {
        case .idle: return ""
        case .permission: return "Waiting for microphone permission"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        }
    }
    @ViewBuilder private var label: some View {
        HStack(spacing: 5) {
            if mine && (voice.phase == .transcribing || voice.phase == .permission) {
                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                Text(voice.phase == .permission ? "Microphone…" : "Transcribing…")
            } else if recording {
                Circle().fill(MacTheme.danger).frame(width: 7, height: 7)
                Text("Recording · click to paste")
            } else {
                Image(systemName: "mic")
                Text("Dictate")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(recording ? MacTheme.danger.opacity(0.14) : MacTheme.panel))
        .overlay(Capsule().stroke(recording ? MacTheme.danger.opacity(0.6) : MacTheme.rule))
        .contentShape(Capsule())
    }
    private var help: String {
        if elsewhere { return "Dictating in “\(voice.originName)”" }
        if recording { return "Stop, transcribe and paste into the prompt without sending (⇧⌘D). Esc discards." }
        if mine { return phaseName }
        return "Dictate into the prompt (⇧⌘D): records with this Mac’s microphone, transcribes on the dictation host, pastes without sending"
    }
    private var accessibility: String {
        if recording { return "Stop dictation and paste" }
        if mine && voice.phase == .transcribing { return "Transcribing dictation" }
        return "Dictate"
    }
}
