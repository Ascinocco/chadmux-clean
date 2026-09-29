import XCTest
@testable import Chadmux
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The terminal draws JetBrains Mono (cmux/Ghostty's default), bundled with the app.
@MainActor
final class TerminalFontTests: XCTestCase {
    func testBundledFacesRegisterAndAreMonospaced() {
        XCTAssertTrue(TerminalFont.available, "all four faces ship in the app and register")
        for face in TerminalFont.Face.allCases {
            XCTAssertEqual(TerminalFont.font(face, size: 13).fontName, face.rawValue)
        }
        let font = TerminalFont.font(.regular, size: 13)
        #if os(macOS)
        XCTAssertTrue(font.isFixedPitch)
        #else
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        #endif
        let licence = Bundle.main.url(forResource: "JetBrainsMono-OFL", withExtension: "txt")
        XCTAssertNotNil(licence, "the OFL licence ships with the font")
    }

    func testFallsBackToTheSystemMonospacedFont() {
        let regular = TerminalFont.font(.regular, size: 13, bundled: false)
        XCTAssertNotEqual(regular.fontName, TerminalFont.Face.regular.rawValue)
        XCTAssertEqual(regular.pointSize, 13)
        let bold = TerminalFont.font(.bold, size: 13, bundled: false)
        XCTAssertNotEqual(bold.fontName, regular.fontName, "bold still differs from regular")
    }

    func testTheTerminalUsesItWithRealBoldAndItalicFaces() {
        #if os(macOS)
        let view = MacNativeTerminalView(frame: .zero)
        view.useChadmuxColors()
        XCTAssertEqual(view.font.fontName, "JetBrainsMono-Regular")
        XCTAssertEqual(view.font.pointSize, 13)
        // SwiftTerm derives bold/italic through the font manager: they must be real faces.
        XCTAssertEqual(NSFontManager.shared.convert(view.font, toHaveTrait: .boldFontMask).fontName, "JetBrainsMono-Bold")
        XCTAssertEqual(NSFontManager.shared.convert(view.font, toHaveTrait: .italicFontMask).fontName, "JetBrainsMono-Italic")
        XCTAssertEqual(NSFontManager.shared.convert(view.font, toHaveTrait: [.boldFontMask, .italicFontMask]).fontName, "JetBrainsMono-BoldItalic")
        #else
        let view = NativeTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.useChadmuxColors()
        XCTAssertEqual(view.font.fontName, "JetBrainsMono-Regular")
        XCTAssertEqual(view.font.pointSize, 12, "the iPhone keeps its size")
        #endif
    }
}
