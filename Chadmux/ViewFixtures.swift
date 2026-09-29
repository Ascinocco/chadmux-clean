#if DEBUG
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// UI-test launch fixtures shared by the iOS and Mac apps. Only explicit
/// launch arguments enable them; the live ones open a disposable connection.
@MainActor
enum ViewFixtures {
    /// The fixture host model for this launch, if any.
    static func model() -> HostsModel? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") && arguments.contains("--reset-test-profile") {
            try? FileManager.default.removeItem(at: RecoveryStore().directory)
            try? FileManager.default.removeItem(at: MediaStore().directory)
        }
        if let multiHost = NativeScrollFixture.multiHost() { return multiHost }
        if let fixture = workspace() {
            let model = HostsModel(fixture: [("Mac", fixture)])
            NativeScrollFixture.routeDictation(model)
            return model
        }
        return nil
    }

    /// Explicit view-state fixtures; only the live ones open a (disposable) connection.
    static func workspace() -> SessionWorkspace? {
        if let live = NativeScrollFixture.workspace() { return live }
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--session-error-ui-fixture") || arguments.contains("--composer-ui-fixture") || arguments.contains("--photo-ui-fixture") else { return nil }
        let workspace = SessionWorkspace(recovery: RecoveryStore())
        // A saved host, so a relaunch without the fixture restores its drafts like a real one.
        let fixtureHost = HostProfile(label: "Mac", connection: MacConnection(host: "fixture.example", port: 22, username: "fixture"))
        try? HostStore(preferences: workspace.connection.preferences).save([fixtureHost])
        workspace.connection.profile = fixtureHost.connection
        let tab = SessionTab(session: RemoteSession(id: "$0", name: "Fixture"), profile: fixtureHost.connection, secrets: workspace.connection.secrets)
        if arguments.contains("--session-error-ui-fixture") {
            tab.transport.connected = true
            tab.transport.errorMessage = "Terminal resize failed. Reconnect to restore the correct size."
        }
        workspace.tabs = [tab]; workspace.selectedID = tab.id
        if arguments.contains("--photo-ui-fixture") {
            Task {
                for color in [(1.0, 0.0, 0.0), (0.0, 0.0, 1.0)] {
                    let data = png(red: color.0, green: color.1, blue: color.2)
                    if let attachment = try? await tab.media.importImage(data) {
                        tab.attachments.append(attachment); tab.thumbnails[attachment.id] = tab.media.thumbnail(attachment)
                    }
                }
            }
        }
        if arguments.contains("--voice-ui-fixture") {
            tab.draft = "My revised draft"; tab.pendingTranscript = "Please inspect the test failure"
            tab.dictationStatus = "Your draft changed. Review the transcript below, then insert or discard it."
        }
        if arguments.contains("--composer-ui-fixture") || arguments.contains("--photo-ui-fixture") {
            let other = SessionTab(session: RemoteSession(id: "$1", name: "Second"), profile: fixtureHost.connection, secrets: workspace.connection.secrets)
            workspace.tabs.append(other)
            workspace.sessions = workspace.tabs.map(\.session)
        }
        return workspace
    }

    /// A small invented solid-colour PNG.
    static func png(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
#endif
