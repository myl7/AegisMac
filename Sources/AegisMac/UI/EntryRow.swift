import SwiftUI

// MARK: - Partially-rounded rectangle (for favorite-run corner merging)

/// A rounded rect where the top and bottom corner radii can be toggled independently, used to
/// merge a run of consecutive favorites into one block (ui-style spec §3.3).
struct RoundedCornersShape: Shape {
    var radius: CGFloat = 12
    var roundTop: Bool = true
    var roundBottom: Bool = true

    func path(in rect: CGRect) -> Path {
        let tr = roundTop ? radius : 0
        let br = roundBottom ? radius : 0
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + tr))
        p.addArc(center: CGPoint(x: rect.minX + tr, y: rect.minY + tr), radius: tr,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr,
                 startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + br, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + br, y: rect.maxY - br), radius: br,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - EntryRow

struct EntryRow: View {
    let entry: VaultEntry
    let roundTop: Bool
    let roundBottom: Bool
    let showPerCardBar: Bool          // true when this entry's period differs from the dominant one

    var onEdit: () -> Void = {}
    var onAssignGroups: () -> Void = {}
    var onShowQR: () -> Void = {}
    var onDelete: () -> Void = {}

    @EnvironmentObject var app: AppState
    @Environment(\.palette) private var palette

    private var mode: ViewMode { app.viewMode }
    private var isSelected: Bool { app.selectedEntry == entry.uuid }
    private var isCopied: Bool { app.copiedEntry == entry.uuid }

    // Resolved account-name position (TILES coerces END → BELOW).
    private var namePosition: AccountNamePosition {
        var pos = app.accountNamePosition
        if mode == .tiles && pos == .end { pos = .below }
        return pos
    }

    private var showAccountName: Bool {
        namePosition != .hidden && app.shouldShowAccountName(for: entry) && !entry.name.isEmpty
    }

    // MARK: Code strings

    private var rawCode: String { entry.info.codeString(at: app.nowSeconds) }

    private var groupedCode: String {
        CodeFormatter.group(rawCode, grouping: app.codeGrouping, disabled: entry.info.isGroupingDisabled)
    }

    private var displayCode: String {
        app.isRevealed(entry) ? groupedCode : CodeFormatter.hidden(groupedCode)
    }

    private var nextGroupedCode: String {
        guard let period = entry.info.totpPeriod else { return "" }
        let next = entry.info.codeString(at: app.nowSeconds + Int64(period))
        return CodeFormatter.group(next, grouping: app.codeGrouping, disabled: entry.info.isGroupingDisabled)
    }

    private var showNext: Bool { app.showNextCode && entry.info.isTotpFamily }

    var body: some View {
        content
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.cardFill(mode))
        .overlay(alignment: .leading) { favoriteSliver }
        .overlay(alignment: .bottom) { perCardProgress }
        .clipShape(RoundedCornersShape(radius: 12, roundTop: roundTop, roundBottom: roundBottom))
        .contentShape(Rectangle())
        .onTapGesture { app.handleTap(entry) }
        .contextMenu { contextMenu }
    }

    // MARK: Main content row

    private var content: some View {
        HStack(spacing: 0) {
            if app.showIcons {
                EntryIconView(iconData: entry.icon?.bytes,
                              issuer: entry.issuer,
                              name: entry.name,
                              size: mode.iconSize)
                    .padding(.leading, mode == .tiles ? 6 : 14)
                    .padding(.trailing, mode == .tiles ? 6 : 12)
                    .overlay { selectionOverlay }
            } else {
                Spacer().frame(width: 14)
            }

            VStack(alignment: .leading, spacing: 2) {
                descriptionBlock
                codeBlock
                if showNext {
                    Text(nextGroupedCode)
                        .font(.system(size: mode.nextCodeFontSize, weight: .bold).monospacedDigit())
                        .foregroundColor(palette.onSurfaceDimColor)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, mode.rowVerticalPadding + 6)

            Spacer(minLength: 4)

            if entry.info.isHotp {
                Button {
                    app.incrementHotp(entry)
                    app.selectedEntry = entry.uuid
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(palette.onSurfaceColor)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .help("Refresh code")
            }
        }
        .padding(.trailing, 8)
    }

    // MARK: Description (issuer + account name, with Copied swap)

    @ViewBuilder private var descriptionBlock: some View {
        ZStack(alignment: .leading) {
            // Copied label
            if isCopied {
                Text("Copied")
                    .font(.system(size: mode.issuerFontSize, weight: .bold))
                    .foregroundColor(palette.primaryColor)
                    .transition(.opacity)
            } else {
                issuerAndName
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isCopied)
    }

    @ViewBuilder private var issuerAndName: some View {
        switch namePosition {
        case .below:
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.issuer.isEmpty ? entry.name : entry.issuer)
                    .font(.system(size: mode.issuerFontSize, weight: .bold))
                    .foregroundColor(palette.onSurfaceColor)
                    .lineLimit(1)
                if showAccountName && !entry.issuer.isEmpty {
                    Text(entry.name)
                        .font(.system(size: mode.issuerFontSize))
                        .foregroundColor(palette.onSurfaceColor)
                        .lineLimit(1)
                }
            }
        case .end, .hidden:
            HStack(spacing: 6) {
                Text(entry.issuer.isEmpty ? entry.name : entry.issuer)
                    .font(.system(size: mode.issuerFontSize, weight: .bold))
                    .foregroundColor(palette.onSurfaceColor)
                    .lineLimit(1)
                if namePosition == .end && showAccountName && !entry.issuer.isEmpty {
                    Text(mode.formattedAccountName(entry.name))
                        .font(.system(size: mode.issuerFontSize))
                        .foregroundColor(palette.onSurfaceColor)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: Code text with expiration animation

    @ViewBuilder private var codeBlock: some View {
        if app.showExpirationState && entry.info.isTotpFamily && app.isRevealed(entry),
           let period = entry.info.totpPeriod {
            TimelineView(.animation) { context in
                let (color, opacity) = expirationStyle(period: period, date: context.date)
                Text(displayCode)
                    .font(.system(size: mode.codeFontSize, weight: .bold).monospacedDigit())
                    .foregroundColor(app.isRevealed(entry) ? color : palette.codeHiddenColor)
                    .opacity(opacity)
                    .lineLimit(1)
                    .environment(\.layoutDirection, .leftToRight)
            }
        } else {
            Text(displayCode)
                .font(.system(size: mode.codeFontSize, weight: .bold).monospacedDigit())
                .foregroundColor(app.isRevealed(entry) ? palette.codeColor : palette.codeHiddenColor)
                .lineLimit(1)
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    /// Expiration warning: hold normal color, fade to error over 300 ms starting at
    /// period-7000-300 ms, then blink alpha 1.0↔0.5 (500 ms half-cycles) during the last 3000 ms.
    private func expirationStyle(period: Int, date: Date) -> (Color, Double) {
        let normal = palette.codeColor
        let error = palette.errorColor
        if period <= 7 { return (error, 1.0) }

        let p = Double(period) * 1000.0
        let millis = date.timeIntervalSince1970 * 1000.0
        let tillRotation = p - millis.truncatingRemainder(dividingBy: p)   // ms until reset

        let colorShift = 300.0
        let warningWindow = 7000.0
        let blink = 3000.0

        if tillRotation > warningWindow + colorShift {
            return (normal, 1.0)
        }
        if tillRotation > warningWindow {
            // fading normal → error over colorShiftDuration
            let f = (warningWindow + colorShift - tillRotation) / colorShift
            return (blend(normal, error, f), 1.0)
        }
        // error color; blink during the last `blink` ms
        if tillRotation <= blink {
            let elapsed = blink - tillRotation
            let phase = (elapsed.truncatingRemainder(dividingBy: 500.0)) / 500.0  // 0..1
            // triangle wave between 1.0 and 0.5
            let tri = phase < 0.5 ? (1.0 - phase * 2) : ((phase - 0.5) * 2)
            let alpha = 0.5 + 0.5 * tri
            return (error, alpha)
        }
        return (error, 1.0)
    }

    private func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let tc = max(0, min(1, t))
        let ca = NSColor(a).usingColorSpace(.sRGB) ?? .white
        let cb = NSColor(b).usingColorSpace(.sRGB) ?? .white
        return Color(.sRGB,
                     red: Double(ca.redComponent) * (1 - tc) + Double(cb.redComponent) * tc,
                     green: Double(ca.greenComponent) * (1 - tc) + Double(cb.greenComponent) * tc,
                     blue: Double(ca.blueComponent) * (1 - tc) + Double(cb.blueComponent) * tc,
                     opacity: 1)
    }

    // MARK: Favorite sliver

    @ViewBuilder private var favoriteSliver: some View {
        if entry.favorite {
            RoundedRectangle(cornerRadius: 4)
                .stroke(palette.favoriteColor, lineWidth: 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(palette.favoriteColor))
                .frame(width: 4)
                .padding(.leading, 0)
        }
    }

    // MARK: Selection overlay

    @ViewBuilder private var selectionOverlay: some View {
        if isSelected && app.showIcons {
            ZStack {
                Circle().fill(palette.primaryColor)
                Image(systemName: "checkmark")
                    .foregroundColor(Color(hex: "f7f7f7"))
                    .font(.system(size: mode.iconSize * 0.4, weight: .bold))
            }
            .frame(width: mode.iconSize, height: mode.iconSize)
            .padding(.leading, mode == .tiles ? 6 : 14)
            .padding(.trailing, mode == .tiles ? 6 : 12)
            .opacity(0.9)
        }
    }

    // MARK: Per-card progress bar

    @ViewBuilder private var perCardProgress: some View {
        if showPerCardBar, let period = entry.info.totpPeriod, !entry.info.isHotp {
            TotpProgressBar(period: period, color: palette.progressbarColor, height: mode.progressBarHeight)
        }
    }

    // MARK: Context menu

    @ViewBuilder private var contextMenu: some View {
        Button("Copy code") { app.copyCode(entry) }
        if entry.info.isTotpFamily {
            Button("Copy next code") { app.copyCode(entry, offset: 1) }
        }
        Divider()
        Button("Edit") { onEdit() }
        Button(entry.favorite ? "Remove favorite" : "Set favorite") { app.toggleFavorite(entry) }
        Button("Assign groups") { onAssignGroups() }
        Button("Show QR code") { onShowQR() }
        Divider()
        Button("Delete", role: .destructive) { onDelete() }
    }
}
