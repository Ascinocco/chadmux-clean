import XCTest
import Crypto
import NIOSSH
import SwiftTerm
import UIKit
@testable import Chadmux

final class SSHPrimitivesTests: XCTestCase {
    @MainActor
    func testUIKitTerminalDecodesANSIAndUnicodeAcrossChunks() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        let bytes = Array("\u{1b}[31mHello 你好\u{1b}[0m\r\nnext".utf8)
        // Split inside a multibyte character to mimic network packet boundaries.
        for byte in bytes { view.feed(byteArray: [byte][...]) }
        let line = try XCTUnwrap(view.getTerminal().getLine(row: 0))
        let rendered = line.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
        XCTAssertEqual(rendered, "Hello 你好")
        XCTAssertEqual(view.getTerminal().getLine(row: 1)?.translateToString(trimRight: true), "next")
    }

    func testGeneratedDeviceKeyIsAnOpenSSHAuthorizedKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicText = SSHPrimitives.authorizedKey(privateKey)
        let decoded = try NIOSSHPublicKey(openSSHPublicKey: publicText)
        XCTAssertEqual(decoded, NIOSSHPrivateKey(ed25519Key: privateKey).publicKey)
        XCTAssertTrue(SSHPrimitives.fingerprint(decoded).hasPrefix("SHA256:"))
        XCTAssertFalse(publicText.contains(privateKey.rawRepresentation.base64EncodedString()))
    }

    func testSessionIDsCannotInjectCommandsOrMatchAnotherSession() throws {
        XCTAssertEqual(try SSHPrimitives.attachCommand(sessionID: "$12"), "exec tmux attach-session -t '$12'")
        for value in ["", "$", "work", "$1; touch /tmp/should-not-exist", "$1\nexit", "$１２"] {
            XCTAssertThrowsError(try SSHPrimitives.attachCommand(sessionID: value))
        }
    }

    func testShellQuotePreservesApostrophesAndShellMetacharacters() {
        XCTAssertEqual(SSHPrimitives.shellQuote("a'b;$(id)"), "'a'\\''b;$(id)'")
    }
}

private final class TerminalOutputProbe: TerminalViewDelegate {
    var bytes: [UInt8] = []
    func send(source:TerminalView,data:ArraySlice<UInt8>) { bytes += data }
    func sizeChanged(source:TerminalView,newCols:Int,newRows:Int) {}
    func setTerminalTitle(source:TerminalView,title:String) {}
    func hostCurrentDirectoryUpdate(source:TerminalView,directory:String?) {}
    func scrolled(source:TerminalView,position:Double) {}
    func requestOpenLink(source:TerminalView,link:String,params:[String:String]) {}
    func bell(source:TerminalView) {}
    func rangeChanged(source:TerminalView,startY:Int,endY:Int) {}
}
extension SSHPrimitivesTests {
    @MainActor
    func testNativeWheelTargetsCellWithoutMouseDragOrArrowKeys() {
        let view = NativeTerminalView(frame:CGRect(x:0,y:0,width:390,height:500))
        let probe = TerminalOutputProbe(); view.terminalDelegate = probe
        view.inputAvailable = true
        view.feed(text:"\u{1b}[?1000h\u{1b}[?1006h")
        let rect = view.getOptimalFrameSize(), terminal = view.getTerminal()
        let point = CGPoint(x:rect.width/CGFloat(terminal.cols)*4.5,y:rect.height/CGFloat(terminal.rows)*6.5)
        view.wheel(1,at:point); view.wheel(-1,at:point)
        XCTAssertEqual(String(decoding:probe.bytes,as:UTF8.self),"\u{1b}[<64;5;7M\u{1b}[<65;5;7M")
        probe.bytes = []; view.inputAvailable = false
        view.wheel(1,at:point); XCTAssertTrue(probe.bytes.isEmpty)
        view.inputAvailable = true; view.feed(text:"\u{1b}[?1000l")
        view.wheel(1,at:point); XCTAssertTrue(probe.bytes.isEmpty)
        view.updateUiClosed()
    }
    @MainActor
    func testLocalUnicodeCopyUsesPhoneClipboardAndSendsNothing() {
        let view = NativeTerminalView(frame:CGRect(x:0,y:0,width:390,height:500))
        let probe = TerminalOutputProbe(); view.terminalDelegate = probe
        view.feed(text:"café 你好\r\nsecond line")
        view.beginSelection(at:CGPoint(x:10,y:10))
        let selection = view.subviews.compactMap { $0 as? UITextView }.first!
        selection.selectedRange = NSRange(location:0,length:("café 你好\nsecond line" as NSString).length)
        selection.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string,"café 你好\nsecond line")
        XCTAssertTrue(probe.bytes.isEmpty)
        XCTAssertFalse(view.hasActiveSelection)
        UIPasteboard.general.items = []
        view.updateUiClosed()
    }
}

extension SSHPrimitivesTests {
    @MainActor
    func testSelectionSnapshotPreservesSoftWrappedUnicode() {
        let view = NativeTerminalView(frame:CGRect(x:0,y:0,width:390,height:500))
        let expected = String(repeating:"abcdef",count:15) + " café 你好 🐈"
        view.feed(text:expected)
        XCTAssertEqual(view.visibleText().trimmingCharacters(in:.newlines),expected)
        view.beginSelection(at:CGPoint(x:5,y:5))
        let selection = view.subviews.compactMap { $0 as? UITextView }.first!
        selection.selectedRange = NSRange(location:0,length:(expected as NSString).length)
        selection.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string,expected)
        XCTAssertTrue(view.isAccessibilityElement)
        XCTAssertFalse(view.subviews.contains(where:{$0 is UITextView}))
        UIPasteboard.general.items = []; view.updateUiClosed()
    }
}

extension SSHPrimitivesTests {
    @MainActor
    func testPaneSelectionExcludesDividerAndAdjacentPaneWithStatusAndOffsets() {
        let metadata = "0|0|39|23|0|0|top|1\n40|0|40|23|1|0|top|1"
        XCTAssertEqual(MacTransport.paneRectangle(metadata,at:CGPoint(x:5,y:3),cols:80,rows:24),CGRect(x:0,y:1,width:39,height:23))
        XCTAssertNil(MacTransport.paneRectangle(metadata,at:CGPoint(x:39,y:3),cols:80,rows:24))
        XCTAssertEqual(MacTransport.paneRectangle(metadata,at:CGPoint(x:5,y:3),cols:40,rows:24,offset:CGPoint(x:40,y:0)),CGRect(x:0,y:1,width:40,height:23))
        XCTAssertNil(MacTransport.paneRectangle("bad metadata",at:.zero,cols:80,rows:24))
    }
}
