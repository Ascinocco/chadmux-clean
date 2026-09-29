# Chadmux icon

The owner's chosen direction: solid black with only lowercase white `chadmux`, centered horizontally and vertically with space on both sides. The wordmark uses Menlo Bold, outlined into paths so the SVG requires no installed font. Visible glyph bounds span 64% of the square width, leaving 18% margins on either side. Both axes center the actual ink bounds.

`chadmux-icon.svg` is the portable vector artwork. The matching opaque 1024 × 1024 PNG lives in `Chadmux/Assets.xcassets/AppIcon.appiconset`; iOS supplies the corner mask. No generated imagery, external service, or private data was used.

To regenerate both files on macOS, run `swift scripts/generate-icon.swift` from the repository root. The script uses the system Menlo Bold font and draws the same glyph paths to both formats. Xcode compiles the universal iOS icon asset for the supported iOS 17+ deployment target.
