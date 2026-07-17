import SwiftUI

// MARK: - Shape: rectangle with only the trailing (right) corners rounded

/// A rectangle whose left corners are square and right corners rounded — mirrors the Aegis
/// TotpProgressBar progress drawable (top-right & bottom-right corners rounded 2 dp).
struct RightRoundedRect: Shape {
    var radius: CGFloat = 2

    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - TOTP countdown progress bar

/// A determinate, linearly-draining TOTP countdown bar. The filled portion (left-aligned)
/// shrinks toward the right and resets at each rotation boundary. Uses TimelineView(.animation)
/// so it redraws smoothly while visible and automatically pauses when the view is offscreen /
/// the window is hidden.
struct TotpProgressBar: View {
    let period: Int
    let color: Color
    var height: CGFloat = 4

    private func fraction(at date: Date) -> Double {
        guard period > 0 else { return 0 }
        let p = Double(period) * 1000.0
        let millis = date.timeIntervalSince1970 * 1000.0
        let tillRotation = p - millis.truncatingRemainder(dividingBy: p)
        return max(0, min(1, tillRotation / p))
    }

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geo in
                let frac = fraction(at: context.date)
                RightRoundedRect(radius: 2)
                    .fill(color)
                    .frame(width: max(0, geo.size.width * frac))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: height)
    }
}
