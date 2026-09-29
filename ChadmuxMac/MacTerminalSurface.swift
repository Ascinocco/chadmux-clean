import SwiftUI
import AppKit

/// The transport's retained Mac terminal in SwiftUI. SwiftUI must not recreate it:
/// it owns the scrollback. The focused terminal backs the Terminal menu commands.
struct MacTerminalSurface: NSViewRepresentable {
    @ObservedObject var transport: MacTransport
    func makeNSView(context: Context) -> MacNativeTerminalView { transport.terminal }
    func updateNSView(_ view: MacNativeTerminalView, context: Context) {}
}

extension FocusedValues {
    @Entry var terminalTransport: MacTransport?
}

/// Terminal menu: clear the local view (Cmd-K) and find (Cmd-F, SwiftTerm's find bar).
struct TerminalCommands: Commands {
    @FocusedValue(\.terminalTransport) private var transport
    @FocusedObject private var actions: MacWindowActions?
    var body: some Commands {
        CommandMenu("Terminal") {
            Button("Clear Screen") {
                guard let transport else { return }
                transport.terminal.clearLocalView()
                Task { await transport.redrawClient() }
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(transport == nil)
            Button("Find…") {
                let finder = NSMenuItem(); finder.tag = NSTextFinder.Action.showFindInterface.rawValue
                transport?.terminal.performTextFinderAction(finder)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(transport == nil)
            Button("Return to Live Output") { Task { await transport?.returnToLive() } }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(transport?.showLiveReturn != true)
            Divider()
            // Start, or stop and paste (⌥⌘D is taken by the system's Dock hiding).
            Button("Dictate / Stop Dictation") { actions?.toggleDictation() }
                .keyboardShortcut("d", modifiers: [.shift, .command])
                .disabled(actions == nil)
            Button("Cancel Dictation") { actions?.cancelDictation() }
                .disabled(actions == nil)
        }
    }
}
