import SwiftUI

// MARK: - Letter avatar (TextDrawableHelper.java + ColorGenerator.java)

/// Generates the fallback letter avatar for an entry, matching Aegis Android exactly:
/// - color palette = the "materialuicolors.co level 700" list in TextDrawableHelper.java
/// - color selection = `palette[abs(javaHashCode(text)) % palette.count]`
/// - the avatar text = issuer (if non-empty) else name (fallback)
/// - the glyph = the first grapheme of that text, uppercased
enum LetterAvatar {
    /// The 19-color level-700 palette used by TextDrawableHelper (0xAARRGGBB → RRGGBB).
    static let palette: [String] = [
        "d32f2f", "c2185b", "7b1fa2", "512da8", "303f9f",
        "1976d2", "0288d1", "0097a7", "00796b", "388e3c",
        "689f38", "afb42b", "fbc02d", "ffa000", "f57c00",
        "e64a19", "5d4037", "616161", "455a64"
    ]

    /// Replicate Java's `String.hashCode()`: s[0]*31^(n-1) + ... + s[n-1], 32-bit wraparound.
    static func javaHashCode(_ s: String) -> Int32 {
        var h: Int32 = 0
        for u in s.utf16 {
            h = h &* 31 &+ Int32(u)
        }
        return h
    }

    /// The color hex for a given avatar text (nil-safe; returns first color for empty).
    static func colorHex(for text: String) -> String {
        guard !text.isEmpty else { return palette[0] }
        let h = javaHashCode(text)
        // Math.abs, guarding Int32.min (Java abs(MIN) stays negative — mirror with magnitude)
        let mag = h == Int32.min ? Int(UInt32(bitPattern: Int32.min)) : Int(abs(h))
        return palette[mag % palette.count]
    }

    /// The letter to render: first grapheme of `text`, uppercased.
    static func letter(for text: String) -> String {
        guard let first = text.first else { return "" }
        return String(first).uppercased()
    }

    /// Compute (letter, colorHex) for an entry given its issuer + name, or nil if both empty.
    static func avatar(issuer: String, name: String) -> (letter: String, colorHex: String)? {
        var text = issuer
        if text.isEmpty { text = name }
        if text.isEmpty { return nil }
        return (letter(for: text), colorHex(for: text))
    }
}

// MARK: - SwiftUI view

/// A circular letter-avatar view. If both issuer and name are empty, renders a neutral circle.
struct LetterAvatarView: View {
    let issuer: String
    let name: String
    let size: CGFloat

    var body: some View {
        ZStack {
            if let avatar = LetterAvatar.avatar(issuer: issuer, name: name) {
                Circle().fill(Color(hex: avatar.colorHex))
                Text(avatar.letter)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundColor(.white)
            } else {
                Circle().fill(Color(hex: LetterAvatar.palette[0]))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Renders an entry icon: the inline custom image if present, else the letter avatar.
struct EntryIconView: View {
    let iconData: Data?
    let issuer: String
    let name: String
    let size: CGFloat

    var body: some View {
        Group {
            if let data = iconData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                LetterAvatarView(issuer: issuer, name: name, size: size)
            }
        }
    }
}
