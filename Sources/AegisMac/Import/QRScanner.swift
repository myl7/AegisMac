import Foundation
import Vision
import CoreGraphics
import ImageIO
import AppKit
import ScreenCaptureKit

/// QR-code scanning via the Vision framework, plus a full-screen scan built on
/// ScreenCaptureKit. Returns the raw string payloads of every QR code found;
/// callers (`GoogleAuthInfo` / `GoogleAuthMigration`) interpret the payloads.
enum QRScanner {

    /// Scans a single `CGImage` for QR codes, returning every decoded payload.
    static func scan(image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw AegisError.importError("Failed to scan image for QR codes: \(error.localizedDescription)")
        }

        guard let results = request.results else {
            return []
        }
        return results.compactMap { $0.payloadStringValue }
    }

    /// Loads an image file and scans it for QR codes.
    static func scan(imageURL: URL) throws -> [String] {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AegisError.importError("Could not read image at \(imageURL.path)")
        }
        return try scan(image: image)
    }

    /// Captures every connected display and scans each for QR codes. Requires the
    /// Screen Recording permission; throws a descriptive error when it is missing.
    @MainActor
    static func scanScreen() async throws -> [String] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
        } catch {
            throw AegisError.importError(
                "Screen recording permission is required to scan the screen for QR codes. "
                + "Grant AegisMac access under System Settings > Privacy & Security > "
                + "Screen Recording, then try again.")
        }

        if content.displays.isEmpty {
            throw AegisError.importError("No displays available to scan.")
        }

        var payloads: [String] = []
        for display in content.displays {
            guard let image = try? await captureDisplay(display) else {
                continue
            }
            if let found = try? scan(image: image) {
                payloads.append(contentsOf: found)
            }
        }
        return payloads
    }

    /// Captures a single display at its native pixel resolution.
    @MainActor
    private static func captureDisplay(_ display: SCDisplay) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()

        // SCDisplay dimensions are in points; scale up to the backing pixel size so
        // on-screen QR codes carry enough detail for Vision to decode reliably.
        let scale = backingScale(for: display.displayID)
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func backingScale(for displayID: CGDirectDisplayID) -> Double {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               CGDirectDisplayID(number.uint32Value) == displayID {
                return Double(screen.backingScaleFactor)
            }
        }
        return 2.0
    }
}
