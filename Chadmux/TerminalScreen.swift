import CoreGraphics
import SwiftTerm

/// What the SSH transport needs from its terminal view, on either platform:
/// NativeTerminalView on iOS, MacNativeTerminalView on macOS.
@MainActor
protocol TerminalScreen: AnyObject {
    var terminalDelegate: TerminalViewDelegate? { get set }
    /// Where the touched or clicked tmux pane is, for selecting its text.
    var selectionBounds: ((CGPoint) async -> CGRect?)? { get set }
    /// Scroll-wheel ticks at a point, forwarded to the remote application.
    var remoteScroll: ((Int, CGPoint) -> Void)? { get set }
    var inputAvailable: Bool { get set }
    /// The scroll offset of the visible grid within the view.
    var contentOrigin: CGPoint { get }
    func getTerminal() -> Terminal
    func feed(byteArray: ArraySlice<UInt8>)
    func getOptimalFrameSize() -> CGRect
    func dismissSelection()
    func stopMomentum()
    func useChadmuxColors()
}

extension TerminalScreen {
    /// Sends mouse-wheel events at the terminal cell under `point` (tmux or the
    /// app handles its own history). Nothing is sent without mouse reporting.
    func wheel(_ ticks: Int, at point: CGPoint) {
        guard inputAvailable, getTerminal().mouseMode != .off else { return }
        let terminal = getTerminal(), frame = getOptimalFrameSize()
        guard frame.width > 0, frame.height > 0 else { return }
        let col = min(terminal.cols-1, max(0, Int(point.x/(frame.width/CGFloat(terminal.cols)))))
        let row = min(terminal.rows-1, max(0, Int(point.y/(frame.height/CGFloat(terminal.rows)))))
        for _ in 0..<min(8, abs(ticks)) {
            terminal.sendEvent(buttonFlags: ticks > 0 ? 64 : 65, x: col, y: row, pixelX: Int(point.x), pixelY: Int(point.y))
        }
    }
}

#if os(iOS)
typealias PlatformTerminalView = NativeTerminalView
#else
typealias PlatformTerminalView = MacNativeTerminalView
#endif
