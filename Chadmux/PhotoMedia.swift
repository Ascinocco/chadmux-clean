import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif
import Citadel
import NIO
import Logging

struct MediaStore: Sendable {
    static let maximumAttachments = 8
    static let maximumImageBytes = 5 * 1024 * 1024
    let directory: URL
    init(directory: URL? = nil) {
        var defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chadmux/Attachments", isDirectory: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            defaultDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ChadmuxUITestAttachments", isDirectory: true)
        }
        #endif
        self.directory = directory ?? defaultDirectory
    }
    func url(for attachment: DraftAttachment) throws -> URL {
        guard attachment.filename == attachment.id.uuidString.lowercased() + ".jpg", attachment.mediaType == "image/jpeg" else { throw InvalidImage() }
        return directory.appendingPathComponent(attachment.filename)
    }
    func importImage(_ source: Data) async throws -> DraftAttachment {
        let encoded = try await Task.detached { try Self.normalizedJPEG(source) }.value
        try Task.checkCancellation()
        let id = UUID()
        let attachment = DraftAttachment(id: id, filename: id.uuidString.lowercased() + ".jpg")
        try PrivateStorage.createDirectory(directory)
        var privateDirectory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try privateDirectory.setResourceValues(values)
        try PrivateStorage.write(encoded, to: url(for: attachment))
        return attachment
    }
    func data(for attachment: DraftAttachment) throws -> Data {
        let path = try url(for: attachment)
        let size = try path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard size.isRegularFile == true, size.isSymbolicLink != true,
              let count = size.fileSize, count > 0, count <= Self.maximumImageBytes else { throw InvalidImage() }
        return try Data(contentsOf: path)
    }
    func remove(_ attachment: DraftAttachment) throws {
        let path = try url(for: attachment)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    static func normalizedJPEG(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw InvalidImage() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw InvalidImage() }
        // Pixel-only re-encoding strips source filenames, GPS and other metadata.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= maximumImageBytes else { throw InvalidImage() }
        return output as Data
    }
    struct InvalidImage: Error {}

    func thumbnail(_ attachment: DraftAttachment) -> PlatformImage? {
        guard let url = try? url(for: attachment),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceThumbnailMaxPixelSize:180] as CFDictionary) else { return nil }
        #if os(iOS)
        return UIImage(cgImage:image)
        #else
        return NSImage(cgImage:image, size:.zero)
        #endif
    }
}

enum PhotoUpload {
    static func attributes(_ permissions: UInt32) -> SFTPFileAttributes {
        var attributes = SFTPFileAttributes(); attributes.permissions = permissions; return attributes
    }
    static func upload(_ attachments: [DraftAttachment], store: MediaStore, settings: SSHClientSettings,
                       root: String = ".chadmux/uploads",
                       timeout: TimeAmount = .seconds(120),
                       progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> [String] {
        guard !attachments.isEmpty, attachments.count <= MediaStore.maximumAttachments,
              Set(attachments.map(\.id)).count == attachments.count else { throw MediaStore.InvalidImage() }
        // Validate every local file before creating any remote artifacts.
        let images = try attachments.map { (name: $0.id.uuidString.lowercased() + ".jpg", data: try store.data(for: $0)) }
        return try await withOwnedConnection(on: settings.group.next(), timeout: timeout,
            connect: { try await SSHClient.connect(to: settings) }) { client in
            let logger = Logger(label: "chadmux.sftp", factory: { _ in SwiftLogNoOpLogHandler() })
            let sftp = try await client.openSFTP(logger: logger)
            // root is fixed in production; disposable tests supply their own private directory.
            let home = try await sftp.getRealPath(atPath: ".")
            let base = root.hasPrefix("/") ? root : home + "/" + root
            guard base.hasPrefix("/"), base.utf8.count < 2048,
                  !base.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw MediaStore.InvalidImage() }
            // No prompt, attachment name or remote home is interpolated into a shell.
            var prefix = ""
            for component in base.split(separator: "/") {
                prefix += "/" + component
                do { try await sftp.createDirectory(atPath: prefix, attributes: Self.attributes(0o700)) }
                catch {
                    let attributes = try await sftp.getAttributes(at: prefix)
                    guard let mode = attributes.permissions, mode & 0o170000 == 0o040000 else { throw error }
                }
            }
            let canonical = try await sftp.getRealPath(atPath: base)
            let attributes = try await sftp.getAttributes(at: base)
            guard canonical == base, let mode = attributes.permissions, mode & 0o077 == 0 else { throw MediaStore.InvalidImage() }
            let batch = base + "/" + UUID().uuidString.lowercased()
            try await sftp.createDirectory(atPath: batch, attributes: Self.attributes(0o700))
            var created: [String] = []
            do {
                for image in images {
                    try Task.checkCancellation()
                    let path = batch + "/" + image.name
                    created.append(path)
                    try await sftp.withFile(filePath: path, flags: [.write, .create, .forceCreate], attributes: Self.attributes(0o600)) { file in
                        try await file.write(ByteBuffer(bytes: image.data))
                    }
                    await progress(created.count, images.count)
                }
                return created
            } catch {
                // Best effort: interruption may prevent removal. Nothing is submitted;
                // retained orphan batches can be removed with the documented Mac cleanup.
                for path in created { try? await sftp.remove(at: path) }
                try? await sftp.rmdir(at: batch)
                throw error
            }
        }
    }
    static func withOwnedConnection<T: Sendable>(on loop: EventLoop, timeout: TimeAmount,
        connect: @escaping @Sendable () async throws -> SSHClient,
        perform: @escaping @Sendable (SSHClient) async throws -> T) async throws -> T {
        try await LoopbackAPI.bounded(on: loop, timeout: timeout) { owner in
            let client = try await connect()
            // Own the upload connection before SFTP negotiation. A late connection
            // is also closed when cancellation/deadline already finished the caller.
            guard owner.own({ Task { try? await client.close() } }) else { throw CancellationError() }
            try Task.checkCancellation()
            return try await perform(client)
        }
    }
    static func message(_ text: String, paths: [String]) throws -> String {
        guard paths.allSatisfy({ $0.hasPrefix("/") && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) else { throw MediaStore.InvalidImage() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let references = try paths.map { path in String(decoding: try encoder.encode(path), as: UTF8.self) }
        return ([text] + references).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Attachment changes shared by every way of adding images (library, camera,
/// paste, drag and drop, file picker).
@MainActor
extension SessionTab {
    /// Adds image data (pasted, dropped or chosen files), up to the attachment limit.
    func importImages(_ items: [Data]) {
        guard !importing, !sending, !closed, !items.isEmpty else { return }
        importing = true; mediaError = nil
        importTask = Task {
            defer { importing = false; importTask = nil }
            do {
                for data in items {
                    try Task.checkCancellation()
                    guard !closed, attachments.count < MediaStore.maximumAttachments else { throw MediaStore.InvalidImage() }
                    try await appendImage(data)
                }
            } catch {
                if !closed { mediaError = "Could not add every image. Use JPEG, HEIC or PNG images up to 32 MiB; eight attachments maximum. Existing images are retained." }
            }
        }
    }
    func appendImage(_ data: Data) async throws {
        let attachment = try await media.importImage(data)
        guard !closed, !Task.isCancelled else { try? media.remove(attachment); throw CancellationError() }
        attachments.append(attachment)
        thumbnails[attachment.id] = media.thumbnail(attachment)
    }
    func removeImage(_ attachment: DraftAttachment) {
        guard !sending, !importing else { return }
        do {
            guard savedChange({ attachments.removeAll { $0.id == attachment.id } }) else { return }
            try media.remove(attachment); thumbnails[attachment.id] = nil
        } catch { mediaError = "Could not remove the local image. Unlock the device and try again." }
    }
}
