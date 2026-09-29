import SwiftUI

/// A paste is one terminal write, never a shell command assembled from a draft.
enum ComposedMessage {
    static func bytes(_ text: String) throws -> [UInt8] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized.utf8.count <= 65_536 else { throw InvalidText() }
        // In particular, refuse ESC so pasted text cannot end its paste envelope.
        guard normalized.unicodeScalars.allSatisfy({ $0.value >= 32 && !($0.value >= 127 && $0.value <= 159) || $0 == "\n" || $0 == "\t" }) else { throw InvalidText() }
        return Array(("\u{1b}[200~" + normalized + "\u{1b}[201~\r").utf8)
    }
    struct InvalidText: Error {}
}

enum TerminalControl: String, CaseIterable, Identifiable {
    case escape = "Esc", tab = "Tab", up = "↑", down = "↓", left = "←", right = "→", enter = "Enter", interrupt = "Ctrl-C"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .escape: "Terminal Escape"
        case .tab: "Terminal Tab"
        case .up: "Terminal arrow up"
        case .down: "Terminal arrow down"
        case .left: "Terminal arrow left"
        case .right: "Terminal arrow right"
        case .enter: "Terminal Enter"
        case .interrupt: "Terminal Control-C"
        }
    }
    func bytes(applicationCursor: Bool) -> [UInt8] {
        let prefix = applicationCursor ? "\u{1b}O" : "\u{1b}["
        switch self {
        case .escape: return [27]
        case .tab: return [9]
        case .enter: return [13]
        case .interrupt: return [3]
        case .up: return Array((prefix + "A").utf8)
        case .down: return Array((prefix + "B").utf8)
        case .right: return Array((prefix + "C").utf8)
        case .left: return Array((prefix + "D").utf8)
        }
    }
}

extension SessionTab {
    func startSubmission() {
        guard !sending, submissionTask == nil, !closed else { return }
        submissionTask = Task { await submit(); submissionTask = nil }
    }
    func submit() async {
        guard transport.connected, let client = transport.client, !closed else { submissionMessage = "Reconnect before sending. Your draft is retained."; return }
        await submit(pasteEnabled: transport.terminal.getTerminal().bracketedPasteMode, prepare: { selected in
            if selected.isEmpty { return [] }
            let settings = try self.transport.pinnedUploadSettings()
            return try await PhotoUpload.upload(selected, store: self.media, settings: settings) { count, total in
                await MainActor.run { if self.sending && !Task.isCancelled { self.submissionMessage = "Uploaded \(count) of \(total) images…" } }
            }
        }, ready: {
            self.transport.client === client && self.transport.connected && self.transport.terminal.getTerminal().bracketedPasteMode && !self.closed
        }) { bytes in
            try await self.transport.sendBytes(bytes)
        }
    }

    // Boundaries let tests hold uploads/writes open across selection changes.
    func submit(pasteEnabled: Bool,
                prepare: ([DraftAttachment]) async throws -> [String] = { selected in
                    guard selected.isEmpty else { throw MediaStore.InvalidImage() }; return []
                }, ready: () -> Bool = { true }, write: ([UInt8]) async throws -> Void) async {
        guard !sending, !importing, !deliveryUncertain, !closed else { return }
        guard pasteEnabled else {
            submissionMessage = "The remote app is not ready for pasted messages. Open Claude’s input prompt, then try again. You can still use the terminal controls."
            return
        }
        let snapshot = draft, selected = attachments
        do { _ = try ComposedMessage.bytes(selected.isEmpty ? snapshot : (snapshot.isEmpty ? "Images" : snapshot)) }
        catch { submissionMessage = "Enter a message up to 64 KiB without terminal control characters."; return }
        sending = true; preparing = true; submissionMessage = selected.isEmpty ? nil : "Uploading images…"
        defer { sending = false; preparing = false }
        let bytes: [UInt8]
        do {
            let paths = try await prepare(selected)
            guard paths.count == selected.count else { throw MediaStore.InvalidImage() }
            try Task.checkCancellation()
            guard ready(), !closed else { throw MacTransport.NotConnected() }
            bytes = try ComposedMessage.bytes(PhotoUpload.message(snapshot, paths: paths))
        } catch {
            submissionMessage = error is CancellationError ? "Upload cancelled. Draft and images retained." : "Images or connection could not be prepared. Nothing was submitted; draft and images retained. Check SSH and retry."
            return
        }
        preparing = false
        writeInFlight = true
        guard checkpoint() else { writeInFlight = false; submissionMessage = "Nothing submitted: save the draft successfully before sending."; return }
        do {
            try await write(bytes)
            let sent = Set(selected.map(\.id))
            guard savedChange({
                if draft == snapshot { draft = "" }
                attachments.removeAll { sent.contains($0.id) }
                writeInFlight = false
            }) else {
                deliveryUncertain = true
                submissionMessage = "Sent locally, but recovery could not be saved. Draft and images retained; inspect the terminal before retrying."
                return
            }
            for attachment in selected { try? media.remove(attachment); thumbnails[attachment.id] = nil }
            submissionMessage = "Sent to terminal. Check Claude for receipt."
        } catch {
            writeInFlight = false; deliveryUncertain = true
            submissionMessage = "Delivery is uncertain. Your draft is retained. Inspect the terminal before choosing to send again."
        }
    }
}
