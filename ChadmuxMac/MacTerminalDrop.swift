import Foundation

/// Images dropped or pasted onto a Mac terminal. There is no input bar on the
/// Mac: each image is uploaded over SFTP to the session's host (re-encoded
/// without metadata, owner-only in ~/.chadmux/uploads) and its absolute remote
/// path is pasted into the terminal, without Enter, as a local terminal pastes
/// a dropped file. Claude on the host then shows it as `[Image #N]`.
@MainActor
final class TerminalImageDrop: ObservableObject {
    enum State: Equatable {
        case idle
        case uploading(Int)
        case added(Int, skipped: Int = 0)
        case failed(String)
    }
    @Published private(set) var state: State = .idle

    let media: MediaStore
    private let upload: ([DraftAttachment]) async throws -> [String]
    private let write: ([UInt8]) async throws -> Void
    private let ready: () -> Bool
    private let bracketed: () -> Bool
    private var clear: Task<Void, Never>?
    /// Drops and pastes that arrive during an upload wait their turn.
    private var queue: [(images: [Data], skipped: Int, host: String)] = []

    init(media: MediaStore,
         upload: @escaping ([DraftAttachment]) async throws -> [String],
         write: @escaping ([UInt8]) async throws -> Void,
         ready: @escaping () -> Bool,
         bracketed: @escaping () -> Bool) {
        self.media = media; self.upload = upload; self.write = write; self.ready = ready; self.bracketed = bracketed
    }

    var busy: Bool { if case .uploading = state { return true } else { return false } }

    /// Uploads the images and pastes their paths; `skipped` counts dropped items
    /// that were not usable images. Nothing is sent if any step fails, and a
    /// drop during an upload is queued rather than ignored.
    func add(_ images: [Data], skipped: Int = 0, host: String) async {
        guard !images.isEmpty || skipped > 0 else { return }
        if busy { queue.append((images, skipped, host)); return }
        await run(images, skipped: skipped, host: host)
        while !queue.isEmpty, !busy {
            let next = queue.removeFirst()
            await run(next.images, skipped: next.skipped, host: next.host)
        }
    }

    private func run(_ images: [Data], skipped: Int, host: String) async {
        guard !images.isEmpty else {
            return finish(.failed(skipped == 1 ? "That is not an image up to 32 MiB, so nothing was added."
                                               : "None of those are images up to 32 MiB, so nothing was added."))
        }
        guard ready() else { return finish(.failed("Connect to \(host) before adding images.")) }
        guard images.count <= MediaStore.maximumAttachments else {
            return finish(.failed("Add up to \(MediaStore.maximumAttachments) images at a time."))
        }
        clear?.cancel()
        state = .uploading(images.count)
        var local: [DraftAttachment] = []
        defer { for attachment in local { try? media.remove(attachment) } }
        do {
            for image in images { local.append(try await media.importImage(image)) }
        } catch {
            return finish(.failed("Use JPEG, HEIC or PNG images up to 32 MiB."))
        }
        let paths: [String]
        do { paths = try await upload(local) } catch {
            return finish(.failed("Could not upload to \(host). Check the connection and try again."))
        }
        guard paths.count == local.count else {
            return finish(.failed("Could not upload to \(host). Check the connection and try again."))
        }
        guard ready() else {
            return finish(.failed("Uploaded, but the connection to \(host) dropped before the path was pasted."))
        }
        do { try await write(Self.pasteBytes(paths, bracketed: bracketed())) } catch {
            return finish(.failed("Uploaded, but the connection to \(host) dropped before the path was pasted."))
        }
        finish(.added(paths.count, skipped: skipped))
    }

    /// The paths as a terminal pastes dropped files: spaces and backslashes
    /// escaped, separated and followed by a space, and never a newline.
    nonisolated static func pasteBytes(_ paths: [String], bracketed: Bool) -> [UInt8] {
        let text = paths.map { path in
            path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: " ", with: "\\ ")
        }.joined(separator: " ") + " "
        let body = Array(text.utf8).filter { $0 != 10 && $0 != 13 }
        return bracketed ? Array("\u{1b}[200~".utf8) + body + Array("\u{1b}[201~".utf8) : body
    }

    private func finish(_ result: State) {
        state = result
        clear?.cancel()
        clear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, self.state == result else { return }
            self.state = .idle
        }
    }
}
