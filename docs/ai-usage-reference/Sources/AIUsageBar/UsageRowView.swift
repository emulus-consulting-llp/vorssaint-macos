import AppKit

/// One row inside a module: mark, name, relative reset, percentage, bar.
///
///   [◆]  Gemini      resets in 32 min   81%
///        ▓▓▓▓▓▓▓▓░░
final class UsageRowView: NSView {
    struct Content {
        let provider: Provider
        let name: String
        /// `nil` means no reading — say why, and draw no bar.
        let used: Double?
        /// Reset copy when there's a reading, otherwise why there isn't one.
        let detail: String
        let stale: Bool
    }

    static let height: CGFloat = 26
    private static let markBox: CGFloat = 26
    private static let markInset: CGFloat = 4.5
    private static let gutter: CGFloat = 10
    private static let barHeight: CGFloat = 6

    private let content: Content

    init(content: Content, width: CGFloat) {
        self.content = content
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let dimmed = content.stale || content.used == nil
        let brand = Brand.color(content.provider)

        // The tile stays neutral; only the mark inside it carries brand colour.
        let tile = NSRect(x: 0, y: (Self.height - Self.markBox) / 2,
                          width: Self.markBox, height: Self.markBox)
        Brand.tileFill.setFill()
        NSBezierPath(roundedRect: tile, xRadius: 7, yRadius: 7).fill()
        Brand.drawMark(content.provider,
                       in: tile.insetBy(dx: Self.markInset, dy: Self.markInset),
                       alpha: dimmed ? 0.75 : 1.0)

        let bodyX = Self.markBox + Self.gutter
        let bodyWidth = bounds.width - bodyX

        // Service name remains crisp and legible in .labelColor
        let name = attributed(content.name, .systemFont(ofSize: 12, weight: .medium), .labelColor)

        guard let used = content.used else {
            // No reading: say why across the space the bar would have used.
            name.draw(at: NSPoint(x: bodyX, y: bounds.height - 9 - name.size().height))
            let why = attributed(content.detail, .systemFont(ofSize: 11, weight: .regular), .secondaryLabelColor)
            why.draw(at: NSPoint(x: bodyX, y: 2))
            return
        }

        // Percentage and reset time: highly legible in all appearances
        let tone = GaugeRenderer.tone(used: used)
        let percentColor: NSColor = (tone == .neutral) ? .labelColor : tone.color
        let percent = attributed(Format.percent(used),
                                 .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                                 percentColor)
        let reset = attributed(content.detail,
                               .systemFont(ofSize: 11, weight: .regular),
                               .secondaryLabelColor)

        let topY = bounds.height - name.size().height - 1
        name.draw(at: NSPoint(x: bodyX, y: topY))

        let percentSize = percent.size()
        percent.draw(at: NSPoint(x: bounds.maxX - percentSize.width, y: topY - 1))

        let resetSize = reset.size()
        let resetX = bounds.maxX - percentSize.width - 9 - resetSize.width
        if resetX > bodyX + name.size().width + 6 {
            reset.draw(at: NSPoint(x: resetX, y: topY))
        }

        GaugeRenderer.drawCapsule(
            in: NSRect(x: bodyX, y: 0, width: bodyWidth, height: Self.barHeight),
            used: used,
            base: brand,
            fillAlpha: content.stale ? 0.70 : 1.0
        )
    }

    private func attributed(_ text: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }
}
