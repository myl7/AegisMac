import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

// MARK: - QR code rendering

enum QRImage {
    /// Render a string payload to a crisp QR-code NSImage, or nil on failure.
    static func generate(from string: String, scale: CGFloat = 10) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: transformed.extent.width, height: transformed.extent.height))
    }
}

// MARK: - Show QR sheet (transfer an entry)

/// Displays the otpauth:// URI of a single entry as a QR code so it can be transferred to
/// another authenticator. The URI is produced via the Import/Export module (contract API).
struct ShowQRView: View {
    let entry: VaultEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    private var uri: String {
        ImportExport.exportUriList(entries: [entry]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(entry.issuer.isEmpty ? entry.name : entry.issuer)
                .font(.headline)
            if let image = QRImage.generate(from: uri) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .background(Color.white)
                    .padding(8)
                    .background(Color.white)
                    .cornerRadius(8)
            } else {
                Text("Could not render QR code").foregroundColor(palette.errorColor)
            }
            Text(entry.name).font(.subheadline).foregroundColor(palette.onSurfaceDimColor)
            HStack {
                Button("Copy URI") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(uri, forType: .string)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}
