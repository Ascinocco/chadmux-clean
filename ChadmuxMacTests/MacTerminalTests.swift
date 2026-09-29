import XCTest
import AppKit
import SwiftTerm
@testable import Chadmux

/// The native Mac terminal: keys, clipboard, wheel routing and local clear.
@MainActor
final class MacTerminalTests: XCTestCase {
    final class Capture: NSObject, TerminalViewDelegate {
        var bytes: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes += data }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
    private var window: NSWindow!
    private func make() -> (MacNativeTerminalView, Capture) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let view = MacNativeTerminalView(frame: window.contentLayoutRect)
        let capture = Capture()
        view.terminalDelegate = capture
        window.contentView = view
        window.makeFirstResponder(view)
        return (view, capture)
    }
    private func key(_ view: MacNativeTerminalView, _ chars: String, _ ignoring: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, characters: chars, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code)!)
    }

    func testTerminalKeysReachTheSSHWriter() {
        let (view, capture) = make()
        let cases: [(String, String, String, UInt16, NSEvent.ModifierFlags, [UInt8])] = [
            ("Ctrl-C", "\u{03}", "c", 8, .control, [3]),
            ("Ctrl-B (tmux prefix)", "\u{02}", "b", 11, .control, [2]),
            ("Esc", "\u{1b}", "\u{1b}", 53, [], [27]),
            ("Return", "\r", "\r", 36, [], [13]),
            ("Tab", "\t", "\t", 48, [], [9]),
            ("Up", "\u{F700}", "\u{F700}", 126, [.numericPad, .function], [27, 91, 65]),
            ("Down", "\u{F701}", "\u{F701}", 125, [.numericPad, .function], [27, 91, 66]),
            ("Right", "\u{F703}", "\u{F703}", 124, [.numericPad, .function], [27, 91, 67]),
            ("Left", "\u{F702}", "\u{F702}", 123, [.numericPad, .function], [27, 91, 68]),
            ("Option-B as Meta", "∫", "b", 11, .option, [27, 98]),
            ("letter", "a", "a", 0, [], [97]),
        ]
        for (name, chars, ignoring, code, flags, expected) in cases {
            capture.bytes = []
            key(view, chars, ignoring, code, flags)
            XCTAssertEqual(capture.bytes, expected, name)
        }
    }

    /// A private pasteboard, so tests never touch your clipboard.
    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("com.ascinocco.chadmux.test-" + UUID().uuidString))
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    func testCopyAndBracketedPasteUseTheMacClipboard() {
        let (view, capture) = make()
        let pasteboard = board()
        view.pasteboard = pasteboard
        view.feed(text: "COPY-ME-SYNTHETIC")
        view.selectAll(nil)
        view.copy(self)
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("COPY-ME-SYNTHETIC") == true)
        view.feed(text: "\u{1b}[?2004h")   // the remote enables bracketed paste, as Claude does
        pasteboard.clearContents(); pasteboard.setString("line one\nline two", forType: .string)
        capture.bytes = []
        view.paste(self)
        XCTAssertEqual(String(decoding: capture.bytes, as: UTF8.self), "\u{1b}[200~line one\nline two\u{1b}[201~")
        view.feed(text: "\u{1b}[?2004l")   // a plain shell: the text as is
        capture.bytes = []
        view.paste(self)
        XCTAssertEqual(String(decoding: capture.bytes, as: UTF8.self), "line one\nline two")
    }

    /// With tmux's `mouse on` a drag selects in tmux, not here. Cmd-C used to empty
    /// the clipboard then; now it leaves it alone.
    func testCopyWithoutASelectionKeepsTheClipboard() {
        let (view, _) = make()
        let pasteboard = board()
        view.pasteboard = pasteboard
        pasteboard.clearContents(); pasteboard.setString("copied elsewhere", forType: .string)
        view.feed(text: "SCREEN-TEXT")
        view.copy(self)
        XCTAssertEqual(pasteboard.string(forType: .string), "copied elsewhere")
    }

    /// tmux copies a selection with OSC 52; it reaches the Mac clipboard through the transport.
    func testTmuxCopyReachesTheClipboard() {
        let (view, _) = make()
        let pasteboard = board()
        view.pasteboard = pasteboard
        let transport = MacTransport(preferences: UserDefaults(suiteName: "chadmux-osc52-" + UUID().uuidString)!,
                                     secrets: SecretStore(service: "com.chadmux.osc52-" + UUID().uuidString))
        view.terminalDelegate = transport
        view.feed(text: "\u{1b}]52;c;" + Data("from tmux ✓".utf8).base64EncodedString() + "\u{07}")
        XCTAssertEqual(pasteboard.string(forType: .string), "from tmux ✓")
        transport.clipboardCopy(source: view, content: Data())
        XCTAssertEqual(pasteboard.string(forType: .string), "from tmux ✓", "an empty copy changes nothing")
    }

    func testAPasteCannotEndItsBracketEarly() {
        let bytes = MacNativeTerminalView.pasteBytes("a\u{1b}[201~rm -rf x\n", bracketed: true)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "\u{1b}[200~arm -rf x\n\u{1b}[201~")
        XCTAssertEqual(MacNativeTerminalView.pasteBytes("plain", bracketed: false), Array("plain".utf8))
    }

    func testWheelGoesToTheRemoteOnlyWhileItReportsTheMouse() throws {
        let (view, _) = make()
        var forwarded: [(Int, CGPoint)] = []
        view.remoteScroll = { forwarded.append(($0, $1)) }
        view.inputAvailable = true
        let wheel = { (lines: Int32) -> Bool in
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
            return view.forwardWheel(NSEvent(cgEvent: event)!)
        }
        XCTAssertFalse(wheel(3), "without mouse reporting SwiftTerm scrolls its own buffer")
        XCTAssertTrue(forwarded.isEmpty)
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")   // tmux with `mouse on`
        XCTAssertTrue(wheel(3)); XCTAssertTrue(wheel(-2))
        XCTAssertEqual(forwarded.map(\.0), [3, -2], "older is positive, as on iOS")
        view.inputAvailable = false
        XCTAssertFalse(wheel(3), "nothing is sent while disconnected")
        XCTAssertEqual(forwarded.count, 2)
    }

    func testTrackpadDeltasAccumulateIntoWholeTicks() {
        var remainder: CGFloat = 0
        XCTAssertNil(MacNativeTerminalView.wheelTicks(deltaY: 5, precise: true, rowHeight: 16, remainder: &remainder))
        XCTAssertEqual(MacNativeTerminalView.wheelTicks(deltaY: 12, precise: true, rowHeight: 16, remainder: &remainder), 1)
        XCTAssertEqual(remainder, 1, accuracy: 0.001)
        XCTAssertEqual(MacNativeTerminalView.wheelTicks(deltaY: 400, precise: true, rowHeight: 16, remainder: &remainder), 8, "capped per event")
        remainder = 0
        XCTAssertEqual(MacNativeTerminalView.wheelTicks(deltaY: 0.2, precise: false, rowHeight: 16, remainder: &remainder), 1, "a notch always moves")
        XCTAssertNil(MacNativeTerminalView.wheelTicks(deltaY: 0, precise: false, rowHeight: 16, remainder: &remainder))
    }

    func testClearLocalViewEmptiesScreenAndScrollbackWithoutSendingAnything() {
        let (view, capture) = make()
        for line in 0..<60 { view.feed(text: "line \(line)\r\n") }
        capture.bytes = []
        view.clearLocalView()
        let terminal = view.getTerminal()
        let visible = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined()
        XCTAssertEqual(visible, "")
        XCTAssertTrue(capture.bytes.isEmpty, "clearing is local; nothing goes to the host")
    }

    func testRendersASyntheticSession() throws {
        let (view, _) = make()
        view.useChadmuxColors()
        view.feed(text: "\u{1b}[32mclaude\u{1b}[0m synthetic session on Mac\r\n> Explain the failing test\r\n")
        view.layoutSubtreeIfNeeded(); view.display()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size); image.addRepresentation(rep)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Mac terminal, synthetic content"; attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(view.getTerminal().cols, 20)
    }

    func testTheTransportUsesTheMacTerminal() {
        let scope = "com.chadmux.mac-terminal-tests." + UUID().uuidString
        let transport = MacTransport(preferences: UserDefaults(suiteName: scope)!, secrets: SecretStore(service: scope))
        defer { UserDefaults().removePersistentDomain(forName: scope); try? SecretStore(service: scope).remove("device-ed25519") }
        XCTAssertTrue(transport.terminal.terminalDelegate === transport)
        XCTAssertTrue(transport.terminal.optionAsMetaKey)
        XCTAssertFalse(transport.terminal.inputAvailable)
        transport.connected = true
        XCTAssertTrue(transport.terminal.inputAvailable, "input follows the connection, as on iOS")
        transport.connected = false
    }
}
