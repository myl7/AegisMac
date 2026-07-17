import SwiftUI

// MARK: - Color hex helpers

extension Color {
    /// Build a Color from a 6-hex-digit RRGGBB string (opaque).
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v & 0xFF0000) >> 16) / 255.0
        let g = Double((v & 0x00FF00) >> 8) / 255.0
        let b = Double(v & 0x0000FF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Palette (exact hex from ui-style spec §1)

/// A resolved color palette. Values are stored as lowercase 6-digit hex strings so they are
/// directly assertable in tests; `color(_:)` turns them into SwiftUI Colors.
struct Palette: Equatable {
    // Surfaces / background (ui-style §1.1, §1.3)
    let background: String
    let surface: String            // Compact card fill
    let surfaceContainer: String   // Normal/Small/Tile card fill
    let onSurface: String
    let onSurfaceVariant: String
    let outline: String
    let outlineVariant: String
    let primary: String
    let errorContainer: String
    let onErrorContainer: String
    let error: String

    // Aegis-specific semantic colors (ui-style §1.2)
    let code: String           // colorCode — the OTP digits
    let codeHidden: String     // colorCodeHidden — the reveal dots
    let progressbar: String    // colorProgressbar
    let favorite: String       // colorFavorite — gold, constant across themes
    let onSurfaceDim: String   // colorOnSurfaceDim — next-code preview

    func color(_ hex: String) -> Color { Color(hex: hex) }

    // Convenience resolved colors
    var backgroundColor: Color { color(background) }
    var surfaceColor: Color { color(surface) }
    var surfaceContainerColor: Color { color(surfaceContainer) }
    var onSurfaceColor: Color { color(onSurface) }
    var onSurfaceVariantColor: Color { color(onSurfaceVariant) }
    var outlineColor: Color { color(outline) }
    var primaryColor: Color { color(primary) }
    var errorContainerColor: Color { color(errorContainer) }
    var onErrorContainerColor: Color { color(onErrorContainer) }
    var errorColor: Color { color(error) }
    var codeColor: Color { color(code) }
    var codeHiddenColor: Color { color(codeHidden) }
    var progressbarColor: Color { color(progressbar) }
    var favoriteColor: Color { color(favorite) }
    var onSurfaceDimColor: Color { color(onSurfaceDim) }

    /// The fill color for a card in the given view mode. Compact = surface, others = surfaceContainer.
    func cardFill(_ mode: ViewMode) -> Color {
        mode == .compact ? surfaceColor : surfaceContainerColor
    }

    // MARK: Static palettes (verbatim hex from spec)

    static let light = Palette(
        background: "fefbff",
        surface: "fbf8fd",
        surfaceContainer: "efedf1",
        onSurface: "1b1b1f",
        onSurfaceVariant: "44464f",
        outline: "757780",
        outlineVariant: "c5c6d0",
        primary: "2b5bb5",
        errorContainer: "ffdad6",
        onErrorContainer: "410002",
        error: "ba1a1a",
        code: "2b5bb5",
        codeHidden: "c5c6d0",
        progressbar: "2b5bb5",
        favorite: "f9a825",
        onSurfaceDim: "9d9ea2"
    )

    static let dark = Palette(
        background: "1b1b1f",
        surface: "131316",
        surfaceContainer: "1f1f23",
        onSurface: "c7c6ca",
        onSurfaceVariant: "c5c6d0",
        outline: "8f9099",
        outlineVariant: "44464f",
        primary: "b0c6ff",
        errorContainer: "93000a",
        onErrorContainer: "ffdad6",
        error: "ffb4ab",
        code: "b0c6ff",
        codeHidden: "44464f",
        progressbar: "2b5bb5",
        favorite: "f9a825",
        onSurfaceDim: "616371"
    )

    /// AMOLED = Dark, with every surface + background forced to pure black, and
    /// colorCode / colorProgressbar / colorCodeHidden overridden per spec.
    static let amoled = Palette(
        background: "000000",
        surface: "000000",
        surfaceContainer: "000000",
        onSurface: "c7c6ca",
        onSurfaceVariant: "c5c6d0",
        outline: "8f9099",
        outlineVariant: "44464f",
        primary: "b0c6ff",
        errorContainer: "93000a",
        onErrorContainer: "ffdad6",
        error: "ffb4ab",
        code: "ffffff",
        codeHidden: "2f2f2f",
        progressbar: "ffffff",
        favorite: "f9a825",
        onSurfaceDim: "616371"
    )
}

// MARK: - Theme resolution

enum ResolvedTheme {
    /// Resolve a ThemeMode to a concrete Palette, following the OS light/dark for SYSTEM modes.
    static func palette(for mode: ThemeMode, systemIsDark: Bool) -> Palette {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .amoled: return .amoled
        case .system: return systemIsDark ? .dark : .light
        case .systemAmoled: return systemIsDark ? .amoled : .light
        }
    }

    /// A forced SwiftUI ColorScheme for the window, or nil to follow the system.
    static func colorScheme(for mode: ThemeMode) -> ColorScheme? {
        switch mode {
        case .light: return .light
        case .dark, .amoled: return .dark
        case .system, .systemAmoled: return nil
        }
    }
}

// MARK: - Environment plumbing

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette = .light
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
