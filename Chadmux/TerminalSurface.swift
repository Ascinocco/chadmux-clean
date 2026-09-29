import SwiftUI
import SwiftTerm

/// The terminal owns its scrollback; SwiftUI must not recreate it on every update.
struct TerminalSurface: UIViewRepresentable {
    let terminal: TerminalView

    func makeUIView(context: Context) -> TerminalView { terminal }
    func updateUIView(_ view: TerminalView, context: Context) {}
}
