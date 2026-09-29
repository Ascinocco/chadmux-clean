import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import NIO
@testable import Chadmux

final class PhotoTests: XCTestCase {
    @MainActor
    static func image(_ color: UIColor = .red, width: CGFloat = 256) -> Data {
        UIGraphicsImageRenderer(size:CGSize(width:width,height:width/2)).pngData { context in
            color.setFill(); context.fill(CGRect(x:0,y:0,width:width,height:width/2))
        }
    }
    @MainActor
    func testImageNormalizationPrivateStorageAndUnsafeNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = MediaStore(directory:root)
        let original = try XCTUnwrap(CGImageSourceCreateWithData(Self.image(width:4096) as CFData,nil))
        let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(original,0,nil))
        let tagged = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(tagged,UTType.jpeg.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,pixels,[kCGImagePropertyGPSDictionary:[
            kCGImagePropertyGPSLatitude:42.0, kCGImagePropertyGPSLatitudeRef:"N",
            kCGImagePropertyGPSLongitude:71.0, kCGImagePropertyGPSLongitudeRef:"W"
        ]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let taggedSource = try XCTUnwrap(CGImageSourceCreateWithData(tagged as CFData,nil))
        let before = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(taggedSource,0,nil) as? [CFString:Any])
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary], "Invented GPS must exist before testing its removal")
        let attachment = try await store.importImage(tagged as Data)
        let data = try store.data(for:attachment)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int,2048)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int,1024)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(CGImageSourceGetType(source) as String?,"public.jpeg")
        XCTAssertTrue(try root.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        XCTAssertThrowsError(try store.data(for:DraftAttachment(filename:"../../unsafe.jpg")))
        XCTAssertThrowsError(try MediaStore.normalizedJPEG(Data("not an image".utf8)))
        try store.remove(attachment)
        XCTAssertThrowsError(try store.data(for:attachment))
    }
    @MainActor
    func testPartialUploadFailureNeverSubmitsAndRetainsEverything() async throws {
        let secrets = SecretStore(service:"com.chadmux.photo-tests."+UUID().uuidString)
        defer { try? secrets.remove("device-ed25519") }
        let tab = SessionTab(session:RemoteSession(id:"$0",name:"Fixture"),profile:MacConnection(),secrets:secrets)
        let a = UUID(), b = UUID()
        tab.attachments = [DraftAttachment(id:a,filename:a.uuidString.lowercased()+".jpg"),DraftAttachment(id:b,filename:b.uuidString.lowercased()+".jpg")]
        tab.draft = "Compare these"
        var writes = 0
        await tab.submit(pasteEnabled:true,prepare:{ selected in
            XCTAssertEqual(selected.count,2)
            throw MediaStore.InvalidImage() // first transfer completed, second failed
        }) { _ in writes += 1 }
        XCTAssertEqual(writes,0)
        XCTAssertEqual(tab.attachments.count,2)
        XCTAssertEqual(tab.draft,"Compare these")
        XCTAssertFalse(tab.deliveryUncertain)
        await tab.submit(pasteEnabled:true,prepare:{ _ in ["/private/one.jpg"] }) { _ in writes += 1 }
        XCTAssertEqual(writes,0,"A partial path list must not silently submit")
        await tab.submit(pasteEnabled:true,prepare:{ _ in ["/private/one.jpg","/private/two.jpg"] },ready:{false}) { _ in writes += 1 }
        XCTAssertEqual(writes,0,"A changed/disconnected terminal must not receive prepared images")
    }
    @MainActor
    func testPhotosStayWithOriginUntilAllUploadsFinish() async throws {
        let service = "com.chadmux.photo-tests." + UUID().uuidString
        let secrets = SecretStore(service:service), prefs = UserDefaults(suiteName:service)!
        defer { try? secrets.remove("device-ed25519"); prefs.removePersistentDomain(forName:service) }
        let a = SessionTab(session:RemoteSession(id:"$0",name:"A"),profile:MacConnection(),secrets:secrets)
        let b = SessionTab(session:RemoteSession(id:"$1",name:"B"),profile:MacConnection(),secrets:secrets)
        let workspace = SessionWorkspace(connection:MacTransport(preferences:prefs,secrets:secrets))
        workspace.tabs = [a,b]; workspace.selectedID = a.id
        a.draft = "Compare"; b.draft = "Other"
        a.attachments = (0..<2).map { _ in let id = UUID(); return DraftAttachment(id:id,filename:id.uuidString.lowercased()+".jpg") }
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let started = loop.makePromise(of:Void.self), release = loop.makePromise(of:Void.self)
        var messages: [String] = []
        let sending = Task { await a.submit(pasteEnabled:true,prepare:{ selected in
            started.succeed(()); try await release.futureResult.get()
            return ["/private/one.jpg","/private/with spaces/two.jpg"]
        }) { messages.append(String(decoding:$0,as:UTF8.self)) } }
        try await started.futureResult.get()
        workspace.selectedID = b.id
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(a.attachments.count,2)
        release.succeed(())
        await sending.value
        XCTAssertEqual(messages.count,1)
        XCTAssertTrue(messages[0].contains("\"/private/one.jpg\"\n\"/private/with spaces/two.jpg\""))
        XCTAssertTrue(a.attachments.isEmpty)
        XCTAssertEqual(b.draft,"Other")
        XCTAssertNil(b.submissionMessage)
    }
}
