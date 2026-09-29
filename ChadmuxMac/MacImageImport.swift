import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Image data from a paste or a drop: image data itself, or image files. The
/// shared media store validates and re-encodes it (metadata stripped).
enum MacImageImport {
    /// The pasteboard the composer's Cmd-V reads images from. UI tests use a
    /// private one, so they never read or replace the user's clipboard.
    static var pasteboard: NSPasteboard {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return NSPasteboard(name: testPasteboard) }
        #endif
        return .general
    }
    static let testPasteboard = NSPasteboard.Name("com.ascinocco.chadmux.uitest-paste")

    /// Images to attach for Cmd-V, or none when the paste is text (it then
    /// pastes into the draft as usual). Image files copied in Finder count.
    static func images(on pasteboard: NSPasteboard) -> [Data] { pasted(on: pasteboard).images }

    /// What a ⌘V offers: images, plus image files that can't be used (unreadable
    /// or over 32 MiB), counted so they are reported rather than pasted as names.
    /// Empty for a text paste, which is left to the terminal.
    static func pasted(on pasteboard: NSPasteboard) -> Dropped {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !files.isEmpty {
            let images = files.compactMap(read)
            return Dropped(images: images, skipped: files.count - images.count)
        }
        return Dropped(images: imageData(on: pasteboard), skipped: 0)
    }

    private static func imageData(on pasteboard: NSPasteboard) -> [Data] {
        // Text wins: copying from a web page can carry an image alongside the words.
        if pasteboard.string(forType: .string) != nil { return [] }
        return (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.types.first { UTType($0.rawValue)?.conforms(to: .image) == true }.flatMap { item.data(forType: $0) }
        }
    }

    /// Dropped items: image files from Finder, or image data from another app.
    static func images(from providers: [NSItemProvider]) async -> [Data] { await dropped(from: providers).images }

    /// What a drop yields: the images, and how many items were not usable
    /// (not an image, unreadable, or over 32 MiB), so nothing is skipped silently.
    struct Dropped: Equatable { var images: [Data] = []; var skipped = 0 }
    static func dropped(from providers: [NSItemProvider]) async -> Dropped {
        var result = Dropped()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let data = await load(provider, UTType.fileURL.identifier),
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                   let image = read(url) {
                    result.images.append(image)
                } else {
                    result.skipped += 1
                }
            } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }),
                      let data = await load(provider, type), data.count <= 32 * 1024 * 1024 {
                result.images.append(data)
            } else {
                result.skipped += 1
            }
        }
        return result
    }

    /// An image file, refusing anything over the store's 32 MiB limit before reading it.
    static func read(_ url: URL) -> Data? {
        guard url.isFileURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 32 * 1024 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func load(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in continuation.resume(returning: data) }
        }
    }
}
