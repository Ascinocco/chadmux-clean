import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import Chadmux

/// Paste and drop sources for the Mac composer, with invented images only.
/// Uses private named pasteboards, never the user's clipboard.
@MainActor
final class MacComposerTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("com.chadmux.composer-tests." + UUID().uuidString))
        addTeardownBlock { board.releaseGlobally() }
        board.clearContents()
        return board
    }
    private func file(_ name: String, _ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chadmux-composer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
    private func tiff() -> Data { NSImage(data: TestImages.png(.green))!.tiffRepresentation! }

    func testPastedImageDataAttachesButTextPastesAsText() {
        let board = pasteboard()
        board.setData(TestImages.png(.red), forType: .png)
        XCTAssertEqual(MacImageImport.images(on: board), [TestImages.png(.red)])

        board.clearContents()
        board.setData(tiff(), forType: .tiff)
        XCTAssertEqual(MacImageImport.images(on: board).count, 1, "a screenshot or Preview copy is TIFF")

        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("words from a web page", forType: .string)
        item.setData(tiff(), forType: .tiff)
        board.writeObjects([item])
        XCTAssertEqual(MacImageImport.images(on: board), [], "text wins, so it pastes into the draft")

        board.clearContents()
        board.setString("just text", forType: .string)
        XCTAssertEqual(MacImageImport.images(on: board), [])
    }

    func testCopiedImageFilesAttachAndOtherFilesDoNot() throws {
        let board = pasteboard()
        let image = try file("invented.png", TestImages.png(.blue))
        let notes = try file("notes.txt", Data("not an image".utf8))
        board.writeObjects([image as NSURL, notes as NSURL])
        XCTAssertEqual(MacImageImport.images(on: board), [TestImages.png(.blue)])
        board.clearContents()
        board.writeObjects([notes as NSURL])
        XCTAssertEqual(MacImageImport.images(on: board), [])
        XCTAssertNil(MacImageImport.read(try file("empty.png", Data())), "an empty file is refused before reading")
    }

    func testDroppedFilesAndImageDataAttach() async throws {
        let image = try file("dropped.png", TestImages.png(.red))
        let fromFinder = NSItemProvider(contentsOf: image)!
        let fromApp = NSItemProvider(item: TestImages.png(.green) as NSData, typeIdentifier: UTType.png.identifier)
        let text = NSItemProvider(object: "some text" as NSString)
        let notes = NSItemProvider(contentsOf: try file("notes.txt", Data("words".utf8)))!
        let images = await MacImageImport.images(from: [fromFinder, text, fromApp, notes])
        XCTAssertEqual(images, [TestImages.png(.red), TestImages.png(.green)])
    }

    func testPastedTIFFBecomesAStrippedJPEGAttachment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chadmux-composer-media-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let tab = SessionTab(session: RemoteSession(id: "$0", name: "Invented"), profile: MacConnection(host: "fixture.example", port: 22, username: "fixture"),
                             secrets: SecretStore(service: "com.chadmux.composer-tests." + UUID().uuidString), media: MediaStore(directory: directory))
        let board = pasteboard()
        board.setData(tiff(), forType: .tiff)
        tab.importImages(MacImageImport.images(on: board))
        await tab.importTask?.value
        XCTAssertEqual(tab.attachments.count, 1)
        XCTAssertNil(tab.mediaError)
        let stored = try tab.media.data(for: try XCTUnwrap(tab.attachments.first))
        XCTAssertEqual(CGImageSourceGetType(try XCTUnwrap(CGImageSourceCreateWithData(stored as CFData, nil))) as String?, UTType.jpeg.identifier)
        XCTAssertNotNil(tab.thumbnails[tab.attachments[0].id], "a thumbnail for the strip")
    }
}
