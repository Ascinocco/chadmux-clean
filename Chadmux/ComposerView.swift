import SwiftUI
import UIKit

struct MessageComposer: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject var transport: MacTransport
    @FocusState private var editing: Bool
    @EnvironmentObject private var voice: VoiceCoordinator
    var body: some View {
        VStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                controls(Array(TerminalControl.allCases))
                VStack(spacing: 0) {
                    controls([.escape, .tab, .enter, .interrupt])
                    controls([.left, .up, .down, .right])
                }
            }
            if let error = tab.persistenceError { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("recovery.error") }
            if let message = tab.submissionMessage {
                Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("composer.status")
            }
            if tab.preparing {
                Button("Cancel upload") { tab.submissionTask?.cancel() }.font(.caption)
            }
            if tab.deliveryUncertain {
                Button("I’ve checked the terminal") { tab.acknowledgeDelivery() }
                    .font(.caption).accessibilityIdentifier("composer.acknowledge")
            }
            if let status = tab.dictationStatus { Text(status).font(.caption).accessibilityIdentifier("dictation.status") }
            if tab.pendingTranscript != nil {
                TextField("Transcript", text: Binding(get: { tab.pendingTranscript ?? "" }, set: { tab.pendingTranscript = $0 }), axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder).accessibilityIdentifier("dictation.transcript")
                HStack {
                    Button("Insert transcript") {
                        tab.insertTranscript()
                    }.accessibilityIdentifier("dictation.insert")
                    Button("Discard transcript", role: .destructive) { tab.pendingTranscript = nil; tab.dictationStatus = nil }
                }.font(.caption)
            }
            AttachmentStrip(tab: tab)
            TextField("Message to Claude", text: $tab.draft, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder).focused($editing)
                .textInputAutocapitalization(.sentences).autocorrectionDisabled()
                .accessibilityIdentifier("composer.draft")
                .simultaneousGesture(
                    DragGesture(minimumDistance: 30).onEnded { gesture in
                        let movement = gesture.translation
                        if editing, movement.height > 40, movement.height > abs(movement.width) {
                            let selection = ComposerSelectionProbe()
                            UIApplication.shared.sendAction(#selector(UIResponder.checkComposerSelection(_:)), to:nil, from:selection, for:nil)
                            if selection.canDismiss { editing = false }
                        }
                    }
                )
            HStack {
                PhotoActions(tab: tab)
                Button {
                    if voice.phase == .recording && voice.origin === tab { voice.stop() } else { voice.start(tab: tab) }
                } label: { Image(systemName: voice.phase == .recording && voice.origin === tab ? "stop.circle.fill" : "mic") }
                    .accessibilityLabel(voice.phase == .recording && voice.origin === tab ? "Stop dictation" : "Record dictation").accessibilityHint("Appends transcription to this draft; never sends it.")
                    .accessibilityIdentifier("dictation.record")
                    .disabled((voice.active && !(voice.phase == .recording && voice.origin === tab)) || tab.sending || tab.pendingTranscript != nil)
                if editing {
                    Button { editing = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .accessibilityLabel("Dismiss keyboard")
                }
                Spacer()
                Button(tab.sending ? "Sending…" : "Send") { tab.startSubmission() }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("composer.send")
                    .disabled((voice.active && voice.origin === tab) || !transport.connected || tab.sending || tab.deliveryUncertain || tab.importing || (tab.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tab.attachments.isEmpty))
            }
        }.padding(8).background(.bar)
    }
    private func controls(_ keys: [TerminalControl]) -> some View {
        HStack(spacing: 2) {
            ForEach(keys) { key in
                Button(key.rawValue) {
                    let bytes = key.bytes(applicationCursor: transport.terminal.getTerminal().applicationCursor)
                    Task { try? await transport.sendBytes(bytes) }
                }.font(.caption.monospaced()).frame(minWidth: 32, minHeight: 44)
                    .frame(maxWidth: .infinity).accessibilityLabel(key.label)
                    .disabled(!transport.connected || tab.sending)
            }
        }
    }
}

// Ask the actual first responder so native selection-handle drags keep focus.
// A missing text responder fails closed rather than dismissing another control.
private final class ComposerSelectionProbe: NSObject {
    var canDismiss = false
}
extension UIResponder {
    @objc fileprivate func checkComposerSelection(_ probe: ComposerSelectionProbe) {
        guard let input = self as? UITextInput, let range = input.selectedTextRange else { return }
        probe.canDismiss = range.isEmpty
    }
}
