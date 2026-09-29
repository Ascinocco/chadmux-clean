import SwiftUI
import AppKit

/// The app's one host model, created on first use. Under XCTest the app hosts
/// tests only and never creates it, so tests never touch the real device key.
@MainActor
enum MacApp {
    static let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let hosts: HostsModel = {
        #if DEBUG
        // UI-test fixtures: view states, and the disposable live hosts (test-transport.py --mac --multi-ui / --manage-ui).
        if let fixture = ViewFixtures.model() { return fixture }
        #endif
        return HostsModel(preferences: MacTransport.appPreferences(), recovery: RecoveryStore())
    }()
}

@main
struct ChadmuxMacApp: App {
    var body: some Scene {
        WindowGroup("Chadmux", id: "main") {
            Group {
                if MacApp.underTest { Text("Chadmux test host") }
                else { MacWorkspaceView(model: MacApp.hosts) }
            }
            .frame(minWidth: 720, minHeight: 440)
        }
        // cmux-like: no title bar; the sidebar and session header carry the context.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 780)
        .commands { SessionCommands(); TerminalCommands() }
        Settings {
            if !MacApp.underTest {
                HostsSettings(model: MacApp.hosts) { NSApplication.shared.keyWindow?.performClose(nil) }
                    .frame(minWidth: 520, minHeight: 560)
                    .preferredColorScheme(.dark)
            }
        }
    }
}
