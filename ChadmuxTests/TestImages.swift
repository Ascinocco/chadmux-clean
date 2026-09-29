import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Synthetic solid-colour PNGs for tests on iOS and macOS (no UIKit/AppKit).
enum TestImages {
    enum Color { case red, green, blue }
    static func png(_ color: Color = .red, width: Int = 256) -> Data {
        let height = width / 2
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rgb: (CGFloat, CGFloat, CGFloat) = color == .red ? (1, 0, 0) : color == .green ? (0, 1, 0) : (0, 0, 1)
        context.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}
