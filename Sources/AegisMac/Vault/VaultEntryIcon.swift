import Foundation
import CryptoKit

/// The image type of an inline entry icon, mirroring `IconType.java`.
///
/// Only the three "real" types are representable here; an unknown MIME type maps
/// to `nil` (Java's `INVALID`), which the icon parser turns into a swallowed error
/// so the entry ends up icon-less (forward compatibility for new image formats).
enum IconType: String {
    case svg
    case png
    case jpeg

    /// The MIME type string written to `icon_mime` (`IconType.toMimeType`).
    var mimeType: String {
        switch self {
        case .svg: return "image/svg+xml"
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        }
    }

    /// Exact-match the three known MIME strings; anything else -> `nil` (INVALID).
    static func fromMimeType(_ mime: String) -> IconType? {
        switch mime {
        case "image/svg+xml": return .svg
        case "image/png": return .png
        case "image/jpeg": return .jpeg
        default: return nil
        }
    }

    /// Infer the icon type from a filename extension (`IconType.fromFilename`).
    static func fromFilename(_ filename: String) -> IconType? {
        switch (filename as NSString).pathExtension.lowercased() {
        case "svg": return .svg
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        default: return nil
        }
    }
}

/// An inline, base64-encoded entry icon (`VaultEntryIcon.java`).
///
/// Icons are stored directly inside each entry; there is no separate icon store.
/// Identity is defined **solely by the hash** (`hash = SHA256(utf8(mime) || bytes)`).
struct VaultEntryIcon: Equatable {
    /// Longest side (px) raster icons are downscaled to when "optimized".
    static let maxDimens = 512

    /// The raw image bytes (SVG text bytes, PNG or JPEG binary).
    var bytes: Data
    var type: IconType
    /// SHA-256 over `utf8(mimeType) || bytes` (see `generateHash`).
    var hash: Data

    /// Fresh icon; the hash is computed from `bytes` + `type`.
    init(bytes: Data, type: IconType) {
        self.bytes = bytes
        self.type = type
        self.hash = VaultEntryIcon.generateHash(bytes: bytes, type: type)
    }

    /// Icon with a pre-supplied (trusted) hash — used when reading `icon_hash`.
    init(bytes: Data, type: IconType, hash: Data) {
        self.bytes = bytes
        self.type = type
        self.hash = hash
    }

    /// `generateHash`: SHA-256 with the MIME string bytes mixed in **before** the
    /// image bytes. Reproduce exactly for byte-compatible `icon_hash` values.
    static func generateHash(bytes: Data, type: IconType) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(type.mimeType.utf8))
        hasher.update(data: bytes)
        return Data(hasher.finalize())
    }

    /// Icon equality is by hash only (`Arrays.equals(hash)`).
    static func == (lhs: VaultEntryIcon, rhs: VaultEntryIcon) -> Bool {
        return lhs.hash == rhs.hash
    }

    // MARK: JSON

    /// Writes `icon` (+ `icon_mime`/`icon_hash` when present) into `obj`.
    /// A nil icon writes `"icon": null` and nothing else (`VaultEntryIcon.toJson`).
    static func writeJson(_ icon: VaultEntryIcon?, into obj: inout JSONObject) {
        if let icon = icon {
            obj["icon"] = icon.bytes.base64EncodedString()
            obj["icon_mime"] = icon.type.mimeType
            obj["icon_hash"] = HexCodec.encode(icon.hash)
        } else {
            obj["icon"] = NSNull()
        }
    }

    /// Parses an icon from an entry object (`VaultEntryIcon.fromJson`). Returns nil
    /// when there is no icon. Throws on a bad MIME type or malformed base64/hex —
    /// the entry parser deliberately swallows these so a bad icon just drops.
    static func fromJson(_ obj: JSONObject) throws -> VaultEntryIcon? {
        // No "icon" key, or an explicit JSON null -> no icon.
        guard let iconVal = obj["icon"], !(iconVal is NSNull) else {
            return nil
        }
        guard let iconStr = iconVal as? String else {
            throw AegisError.vault("icon value is not a base64 string")
        }

        // Absent icon_mime defaults to JPEG (legacy vaults stored JPEG-only icons).
        let mime = optStringOrNil(obj, "icon_mime")
        let type: IconType
        if let mime = mime {
            guard let parsed = IconType.fromMimeType(mime) else {
                throw AegisError.vault("Bad icon MIME type: \(mime)")
            }
            type = parsed
        } else {
            type = .jpeg
        }

        guard let bytes = Data(base64Encoded: iconStr) else {
            throw AegisError.vault("invalid icon base64")
        }

        // Trust a stored icon_hash; otherwise recompute from bytes + type.
        if let hashStr = optStringOrNil(obj, "icon_hash") {
            let hash = try HexCodec.decode(hashStr)
            return VaultEntryIcon(bytes: bytes, type: type, hash: hash)
        }
        return VaultEntryIcon(bytes: bytes, type: type)
    }

    /// `JsonUtils.optString`: nil when the key is absent or JSON null, else the string.
    private static func optStringOrNil(_ obj: JSONObject, _ key: String) -> String? {
        guard let value = obj[key], !(value is NSNull) else { return nil }
        return value as? String
    }
}
