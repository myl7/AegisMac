import Foundation
import AppKit
import CryptoKit

// MARK: - Icon processing for the editor

enum IconHelper {
    static let maxDimens: CGFloat = 512   // VaultEntryIcon.MAX_DIMENS

    /// Load an image file, downscale so the longest side ≤ 512 px, and re-encode as PNG.
    static func pngData(fromImageAt url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return pngData(from: image)
    }

    static func pngData(from image: NSImage) -> Data? {
        // Determine pixel dimensions from the best bitmap representation.
        var pixelW = image.size.width
        var pixelH = image.size.height
        if let rep = image.representations.first as? NSBitmapImageRep {
            pixelW = CGFloat(rep.pixelsWide)
            pixelH = CGFloat(rep.pixelsHigh)
        }
        let longest = max(pixelW, pixelH)
        let scale = longest > maxDimens ? maxDimens / longest : 1.0
        let targetW = max(1, Int((pixelW * scale).rounded()))
        let targetH = max(1, Int((pixelH * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: targetW, pixelsHigh: targetH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: targetW, height: targetH)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
                   from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// The Aegis icon hash: SHA-256( utf8(mimeType) || imageBytes ), lowercase hex.
    static func hash(mime: String, bytes: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(mime.utf8))
        hasher.update(data: bytes)
        return Data(hasher.finalize())
    }

    static func hexLower(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
