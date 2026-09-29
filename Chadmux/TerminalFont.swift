import CoreText
#if os(iOS)
import UIKit
typealias PlatformFont = UIFont
#else
import AppKit
typealias PlatformFont = NSFont
#endif

/// The terminal's font: JetBrains Mono, the font cmux/Ghostty draw by default,
/// bundled (SIL Open Font License, Fonts/JetBrainsMono-OFL.txt) and registered
/// for this process only. Falls back to the system monospaced font if missing.
enum TerminalFont {
    enum Face: String, CaseIterable {
        case regular = "JetBrainsMono-Regular", bold = "JetBrainsMono-Bold"
        case italic = "JetBrainsMono-Italic", boldItalic = "JetBrainsMono-BoldItalic"
    }
    /// Whether every bundled face is available; registration happens once.
    static let available: Bool = {
        Face.allCases.allSatisfy { face in
            if let url = Bundle.main.url(forResource: face.rawValue, withExtension: "ttf") {
                // Fails harmlessly if already registered; availability is what counts.
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
            return PlatformFont(name: face.rawValue, size: 12) != nil
        }
    }()

    static func font(_ face: Face, size: CGFloat, bundled: Bool = available) -> PlatformFont {
        if bundled, let font = PlatformFont(name: face.rawValue, size: size) { return font }
        switch face {
        case .regular, .italic: return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .bold, .boldItalic: return .monospacedSystemFont(ofSize: size, weight: .bold)
        }
    }
}
