#if os(macOS)
import AppKit
import SwiftTerm

/// SwiftTerm's native Mac terminal as a TerminalScreen. Keyboard and Option as Meta
/// come from SwiftTerm. While the remote application reports the mouse (tmux with
/// `mouse on`), the wheel and drags go to it, as on iOS, so tmux or the app scrolls
/// and selects in its own history.
///
/// Clipboard: tmux copies a mouse selection with OSC 52, which lands on the Mac
/// clipboard (`copyFromHost`). Cmd-C copies this view's own selection (Shift-drag
/// makes one while tmux has the mouse) and leaves the clipboard alone when there is
/// none. Cmd-V pastes text, bracketed when the remote asks.
final class MacNativeTerminalView: TerminalView, TerminalScreen {
    /// The Mac clipboard; a private board under --ui-testing, never your clipboard.
    var pasteboard: NSPasteboard = MacImageImport.pasteboard
    var selectionBounds: ((CGPoint) async -> CGRect?)?
    var remoteScroll: ((Int, CGPoint) -> Void)?
    var inputAvailable = false { didSet { if !inputAvailable { dismissSelection() } } }
    var contentOrigin: CGPoint { .zero }
    private var wheelRemainder: CGFloat = 0

    // SwiftTerm's scrollWheel isn't open for overriding; a local event monitor
    // sees wheel events first and forwards those over this view to the remote.
    private var wheelMonitor: Any?

    override init(frame: CGRect) {
        super.init(frame: frame)
        optionAsMetaKey = true
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            return self.forwardWheel(event) ? nil : event
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    deinit { if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) } }

    func dismissSelection() { selectNone() }

    /// Cmd-C: this view's selection. With none (a drag while tmux has the mouse
    /// selects in tmux instead), SwiftTerm would empty the clipboard; leave it.
    override func copy(_ sender: Any) {
        guard selectionActive, let text = getSelection(), !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Cmd-V: the clipboard's text, bracketed when the remote asks.
    override func paste(_ sender: Any) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        send(Self.pasteBytes(text, bracketed: getTerminal().bracketedPasteMode))
    }

    /// Text as pasted into the terminal. Inside a bracketed paste, an embedded end
    /// marker is dropped so the pasted text can't end the paste early.
    nonisolated static func pasteBytes(_ text: String, bracketed: Bool) -> [UInt8] {
        guard bracketed else { return Array(text.utf8) }
        let body = text.replacingOccurrences(of: "\u{1b}[201~", with: "")
        return Array("\u{1b}[200~".utf8) + Array(body.utf8) + Array("\u{1b}[201~".utf8)
    }

    /// OSC 52 from the host: tmux copying a selection (`set-clipboard`), or an app
    /// asking to set the clipboard. Text only; the host can't read the clipboard.
    func copyFromHost(_ content: Data) {
        guard let text = String(data: content, encoding: .utf8), !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    func stopMomentum() { wheelRemainder = 0 }
    /// The window's flat dark surface (MacTheme.terminal) with JetBrains Mono 13,
    /// as cmux draws by default. Bold and italic resolve to the bundled faces.
    func useChadmuxColors() {
        nativeBackgroundColor = NSColor(srgbRed: 0.071, green: 0.075, blue: 0.086, alpha: 1)
        nativeForegroundColor = NSColor(white: 0.95, alpha: 1)
        font = TerminalFont.font(.regular, size: 13)
    }

    /// Sends the wheel to the remote application while it reports the mouse, as on
    /// iOS. Returns false (SwiftTerm scrolls its own buffer) otherwise.
    func forwardWheel(_ event: NSEvent) -> Bool {
        guard inputAvailable, getTerminal().mouseMode != .off, let remoteScroll else { return false }
        guard let ticks = Self.wheelTicks(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                                          rowHeight: rowHeight, remainder: &wheelRemainder) else { return true }
        let point = convert(event.locationInWindow, from: nil)
        // Wheel encoding counts rows from the top.
        remoteScroll(ticks, CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
        return true
    }
    private var rowHeight: CGFloat { max(1, getOptimalFrameSize().height / CGFloat(max(1, getTerminal().rows))) }

    /// Positive ticks scroll towards older output. Trackpad deltas are pixels,
    /// accumulated a row at a time; a mouse-wheel notch moves at least one tick.
    static func wheelTicks(deltaY: CGFloat, precise: Bool, rowHeight: CGFloat, remainder: inout CGFloat) -> Int? {
        guard deltaY != 0 else { return nil }
        let ticks: Int
        if precise {
            remainder += deltaY
            ticks = max(-8, min(8, Int(remainder / max(1, rowHeight))))
            remainder -= CGFloat(ticks) * max(1, rowHeight)
        } else {
            remainder = 0
            let rounded = Int(deltaY.rounded())
            ticks = max(-8, min(8, rounded != 0 ? rounded : (deltaY > 0 ? 1 : -1)))
        }
        return ticks == 0 ? nil : ticks
    }

    /// Clears this view only (screen and local scrollback); the transport then
    /// asks tmux to redraw this client. Remote history is never changed.
    func clearLocalView() {
        feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
    }
}
#endif
