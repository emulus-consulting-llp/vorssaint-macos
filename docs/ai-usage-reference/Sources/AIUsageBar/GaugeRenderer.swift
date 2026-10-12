import AppKit

/// How much attention a reading deserves. Colour is reserved for the states
/// that warrant it: a permanently coloured menu bar item would be noise, and
/// noise is exactly what stops a warning from registering.
enum GaugeTone {
    case neutral
    case warning
    case critical

    var color: NSColor {
        switch self {
        case .neutral: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

/// Draws the capsule gauge used by both the menu bar item and the dropdown rows.
enum GaugeRenderer {
    /// Past this much consumption the gauge turns amber, then red. Chosen so
    /// the colour changes while there's still time to act, not at the wall.
    static let warnAbove = 0.70
    static let criticalAbove = 0.90

    static func tone(used: Double) -> GaugeTone {
        if used > criticalAbove { return .critical }
        if used > warnAbove { return .warning }
        return .neutral
    }

    // MARK: - Capsule

    /// Fills `rect` with a rounded track and a proportional fill.
    ///
    /// `base` carries the colour; track and fill are alpha variations of it, so
    /// the whole gauge stays self-consistent whatever colour it is drawn in —
    /// including pure black for template rendering.
    static func drawCapsule(
        in rect: NSRect,
        used: Double,
        base: NSColor,
        fillAlpha: CGFloat = 1.0
    ) {
        let radius = rect.height / 2

        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        base.withAlphaComponent(0.18).setFill()
        track.fill()

        let clamped = max(0, min(1, used))
        guard clamped > 0 else { return }

        // Clip to the track and fill a plain rectangle, so the fill borrows the
        // capsule's shape. Rounding the fill itself would make anything narrower
        // than the bar's own height collapse to a dot — which rendered 24% and
        // 10% identically, hiding exactly the difference that matters most.
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        base.withAlphaComponent(fillAlpha).setFill()
        NSRect(
            x: rect.minX,
            y: rect.minY,
            // Never thinner than a visible sliver, so a small non-zero value
            // doesn't disappear entirely.
            width: max(2, rect.width * clamped),
            height: rect.height
        ).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Ring

    /// Stroked arc, filling clockwise from twelve o'clock.
    static func drawRing(
        in rect: NSRect,
        used: Double,
        base: NSColor,
        fillAlpha: CGFloat = 1.0,
        lineWidth: CGFloat? = nil
    ) {
        let width = lineWidth ?? (rect.width * 0.15)
        let radius = (rect.width - width) / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = width
        base.withAlphaComponent(0.20).setStroke()
        track.stroke()

        let clamped = max(0, min(1, used))
        guard clamped > 0 else { return }

        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - 360 * clamped, clockwise: true)
        arc.lineWidth = width
        arc.lineCapStyle = .round
        base.withAlphaComponent(fillAlpha).setStroke()
        arc.stroke()
    }

    // MARK: - Menu bar item

    private static let ringSize: CGFloat = 14
    private static let ringLineWidth: CGFloat = 1.45
    private static let gap: CGFloat = 5
    /// Standard macOS menu bar extra content height.
    private static let itemHeight: CGFloat = 22
    /// Subtle horizontal breathing room at the ends of the status item.
    private static let padX: CGFloat = 2

    /// The whole menu bar item -- ring and percentage -- conforming to Apple HIG.
    ///
    /// Background is transparent (no artificial chip/pill box) so it floats
    /// naturally on the menu bar's native vibrancy and smoothly accepts AppKit's
    /// system highlight capsule when clicked.
    ///
    /// Neutral state is a template image so macOS manages light, dark, and
    /// selection-highlight tinting automatically. Amber and red states carry
    /// explicit system warning colors.
    static func statusItemImage(used: Double?, stale: Bool) -> NSImage {
        let tone = used.map(tone(used:)) ?? .neutral
        let isTemplate = (tone == .neutral)
        let base: NSColor = isTemplate ? .black : tone.color

        let text = used.map(Format.percent) ?? "--"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: base
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)

        // Reserve room for the widest value the field can hold (100%) so the
        // item doesn't jitter in width as usage fluctuates.
        let textWidth = ceil(NSAttributedString(string: "100%", attributes: attributes).size().width)
        let textSize = attributed.size()

        let size = NSSize(width: padX * 2 + ringSize + gap + textWidth, height: itemHeight)

        let image = NSImage(size: size, flipped: false) { _ in
            let ringY = (itemHeight - ringSize) / 2
            let ring = NSRect(x: padX, y: ringY, width: ringSize, height: ringSize)

            // A stale reading draws softer, indicating aged data.
            drawRing(
                in: ring,
                used: used ?? 0,
                base: base,
                fillAlpha: stale ? 0.45 : 1.0,
                lineWidth: ringLineWidth
            )

            // Right-aligned in the reserved field so digits stay optically stable.
            attributed.draw(at: NSPoint(
                x: padX + ringSize + gap + (textWidth - ceil(textSize.width)),
                y: (itemHeight - textSize.height) / 2
            ))
            return true
        }
        image.isTemplate = isTemplate
        return image
    }
}
