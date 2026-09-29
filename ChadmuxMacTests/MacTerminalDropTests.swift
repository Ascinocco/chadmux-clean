import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import Chadmux

/// Images dropped or pasted onto the Mac terminal: uploaded, then their remote
/// paths pasted without Enter. Upload and terminal writes are injected here.
@MainActor
final class MacTerminalDropTests: XCTestCase {
    private func media() -> MediaStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chadmux-drop-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return MediaStore(directory: directory)
    }
    private func localFiles(_ store: MediaStore) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
    }

    func testPasteBytesLookLikeATerminalFileDropAndNeverPressEnter() {
        XCTAssertEqual(String(decoding: TerminalImageDrop.pasteBytes(["/home/user/.chadmux/uploads/b/one.jpg"], bracketed: true), as: UTF8.self),
                       "\u{1b}[200~/home/user/.chadmux/uploads/b/one.jpg \u{1b}[201~")
        XCTAssertEqual(String(decoding: TerminalImageDrop.pasteBytes(["/a b/one.jpg", "/c\\d/two.jpg"], bracketed: false), as: UTF8.self),
                       "/a\\ b/one.jpg /c\\\\d/two.jpg ", "spaces and backslashes escaped; space-separated with a trailing space")
        let hostile = TerminalImageDrop.pasteBytes(["/x\n/y\r.jpg"], bracketed: true)
        XCTAssertFalse(hostile.contains(10)); XCTAssertFalse(hostile.contains(13))
    }

    func testAddUploadsThenPastesThePathsAndCleansUp() async throws {
        let store = media()
        var uploaded: [DraftAttachment] = []
        var written: [[UInt8]] = []
        let drop = TerminalImageDrop(media: store,
            upload: { attachments in uploaded = attachments; return attachments.map { "/home/me/.chadmux/uploads/b/" + $0.filename } },
            write: { written.append($0) }, ready: { true }, bracketed: { true })
        await drop.add([TestImages.png(.red), TestImages.png(.blue)], host: "Mac")
        XCTAssertEqual(drop.state, .added(2))
        XCTAssertEqual(uploaded.count, 2)
        XCTAssertEqual(written, [TerminalImageDrop.pasteBytes(uploaded.map { "/home/me/.chadmux/uploads/b/" + $0.filename }, bracketed: true)])
        XCTAssertEqual(localFiles(store), [], "the local copies are removed after upload")
    }

    func testNothingIsPastedWhenAStepFails() async {
        struct Failure: Error {}
        var written = 0, uploads = 0
        func drop(ready: Bool = true, upload: @escaping ([DraftAttachment]) async throws -> [String] = { $0.map { "/r/" + $0.filename } }) -> TerminalImageDrop {
            TerminalImageDrop(media: media(), upload: { uploads += 1; return try await upload($0) }, write: { _ in written += 1 },
                              ready: { ready }, bracketed: { true })
        }
        let offline = drop(ready: false)
        await offline.add([TestImages.png(.red)], host: "Arch")
        XCTAssertEqual(offline.state, .failed("Connect to Arch before adding images."))
        let tooMany = drop()
        await tooMany.add(Array(repeating: TestImages.png(.red), count: 9), host: "Mac")
        XCTAssertEqual(tooMany.state, .failed("Add up to 8 images at a time."))
        let notAnImage = drop()
        await notAnImage.add([Data("not an image".utf8)], host: "Mac")
        XCTAssertEqual(notAnImage.state, .failed("Use JPEG, HEIC or PNG images up to 32 MiB."))
        let uploadFails = drop(upload: { _ in throw Failure() })
        await uploadFails.add([TestImages.png(.green)], host: "Mac")
        XCTAssertEqual(uploadFails.state, .failed("Could not upload to Mac. Check the connection and try again."))
        XCTAssertEqual(localFiles(uploadFails.media), [], "a failed upload leaves no local copy")
        let partial = drop(upload: { _ in [] })
        await partial.add([TestImages.png(.green)], host: "Mac")
        XCTAssertEqual(partial.state, .failed("Could not upload to Mac. Check the connection and try again."))
        XCTAssertEqual(written, 0, "nothing is ever pasted after a failure")
        XCTAssertEqual(uploads, 2, "offline, too many and invalid images never reach the host")
    }

    func testAnEmptyDropDoesNothingAndAddedStatusClearsItself() async throws {
        let drop = TerminalImageDrop(media: media(), upload: { $0.map { "/r/" + $0.filename } }, write: { _ in }, ready: { true }, bracketed: { false })
        await drop.add([], host: "Mac")
        XCTAssertEqual(drop.state, .idle)
        await drop.add([TestImages.png(.red)], host: "Mac")
        XCTAssertEqual(drop.state, .added(1))
        for _ in 0..<60 where drop.state != .idle { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(drop.state, .idle, "the header status goes away")
    }

    func testSkippedDropsAreReportedNotSilent() async {
        var written = 0
        func drop() -> TerminalImageDrop {
            TerminalImageDrop(media: media(), upload: { $0.map { "/r/" + $0.filename } }, write: { _ in written += 1 }, ready: { true }, bracketed: { true })
        }
        let onlySkipped = drop()
        await onlySkipped.add([], skipped: 1, host: "Mac")
        XCTAssertEqual(onlySkipped.state, .failed("That is not an image up to 32 MiB, so nothing was added."))
        let manySkipped = drop()
        await manySkipped.add([], skipped: 3, host: "Mac")
        XCTAssertEqual(manySkipped.state, .failed("None of those are images up to 32 MiB, so nothing was added."))
        XCTAssertEqual(written, 0)
        let mixed = drop()
        await mixed.add([TestImages.png(.red)], skipped: 2, host: "Mac")
        XCTAssertEqual(mixed.state, .added(1, skipped: 2), "the image is added and the skips are reported")
        XCTAssertEqual(written, 1)
    }

    func testADropDuringAnUploadIsQueuedNotLost() async throws {
        var release: CheckedContinuation<Void, Never>?
        var uploads: [Int] = []
        var written: [[UInt8]] = []
        let drop = TerminalImageDrop(media: media(),
            upload: { attachments in
                uploads.append(attachments.count)
                if uploads.count == 1 { await withCheckedContinuation { release = $0 } }
                return attachments.map { "/r/" + $0.filename }
            },
            write: { written.append($0) }, ready: { true }, bracketed: { false })
        let first = Task { await drop.add([TestImages.png(.red)], host: "Mac") }
        for _ in 0..<100 where release == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(drop.busy)
        await drop.add([TestImages.png(.blue), TestImages.png(.green)], host: "Mac")  // arrives mid-upload
        XCTAssertEqual(written.count, 0, "queued, not uploaded concurrently")
        release?.resume()
        await first.value
        XCTAssertEqual(uploads, [1, 2], "both drops uploaded, in order")
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(drop.state, .added(2))
    }

    func testTextPasteIsLeftToTheTerminal() {
        let board = NSPasteboard(name: NSPasteboard.Name("com.chadmux.drop-tests." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("plain words to paste", forType: .string)
        XCTAssertEqual(MacImageImport.images(on: board), [], "no images: the ⌘V monitor passes the event to the terminal")
        board.clearContents()
        board.setData(TestImages.png(.red), forType: .png)
        XCTAssertEqual(MacImageImport.images(on: board).count, 1, "an image: the monitor uploads it")
    }

    func testDroppedItemsCountWhatIsSkipped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chadmux-drop-items-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("shot.png"); try TestImages.png(.red).write(to: image)
        let notes = directory.appendingPathComponent("notes.txt"); try Data("words".utf8).write(to: notes)
        let empty = directory.appendingPathComponent("empty.png"); try Data().write(to: empty)
        let providers = [NSItemProvider(contentsOf: image)!, NSItemProvider(contentsOf: notes)!, NSItemProvider(contentsOf: empty)!,
                         NSItemProvider(item: TestImages.png(.blue) as NSData, typeIdentifier: UTType.png.identifier),
                         NSItemProvider(object: "some text" as NSString)]
        let dropped = await MacImageImport.dropped(from: providers)
        XCTAssertEqual(dropped.images, [TestImages.png(.red), TestImages.png(.blue)])
        XCTAssertEqual(dropped.skipped, 3, "a text file, an empty image file and plain text")
    }

    func testAPastedImageFileTooLargeIsReportedNotPastedAsAName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chadmux-paste-big-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let big = directory.appendingPathComponent("huge.png")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 33 * 1024 * 1024)  // sparse: 33 MiB logical, no disk used
        try handle.close()
        let small = directory.appendingPathComponent("ok.png"); try TestImages.png(.red).write(to: small)
        let board = NSPasteboard(name: NSPasteboard.Name("com.chadmux.drop-tests." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([big as NSURL])
        XCTAssertEqual(MacImageImport.pasted(on: board), MacImageImport.Dropped(images: [], skipped: 1),
                       "intercepted and reported, not left to the terminal to paste as a file name")
        board.clearContents()
        board.writeObjects([big as NSURL, small as NSURL])
        XCTAssertEqual(MacImageImport.pasted(on: board), MacImageImport.Dropped(images: [TestImages.png(.red)], skipped: 1))
        board.clearContents()
        board.setString("text", forType: .string)
        XCTAssertEqual(MacImageImport.pasted(on: board), MacImageImport.Dropped(), "text: left to the terminal")
    }

    func testADisconnectAfterTheUploadIsNotCalledAnUploadFailure() async {
        var connected = true
        var written = 0
        let drop = TerminalImageDrop(media: media(),
            upload: { attachments in connected = false; return attachments.map { "/r/" + $0.filename } },
            write: { _ in written += 1 }, ready: { connected }, bracketed: { true })
        await drop.add([TestImages.png(.red)], host: "Arch")
        XCTAssertEqual(drop.state, .failed("Uploaded, but the connection to Arch dropped before the path was pasted."))
        XCTAssertEqual(written, 0)
    }
}
