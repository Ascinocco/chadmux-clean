import SwiftUI

@main
struct ChadmuxApp: App {
    init() {
        // Only process startup owns no image import; never collect during view initialization.
        try? RecoveryStore().removeOrphanedMedia(in: MediaStore())
        // A fresh process owns no recorder; remove only abandoned private audio.
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("ChadmuxVoice", isDirectory: true))
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
