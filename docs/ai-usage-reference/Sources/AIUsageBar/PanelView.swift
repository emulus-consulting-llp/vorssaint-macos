import AppKit

/// A small button that draws itself: a filled pill for the primary action, or
/// plain text. AppKit's bezel styles don't match a Control Center footer, and
/// tinting one into shape is more code than drawing it.
final class FooterButton: NSButton {
    enum Style { case pill, plain }

    private let style: Style
    private let label: String
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(label: String, style: Style, target: AnyObject?, action: Selector) {
        self.style = style
        self.label = label
        super.init(frame: .zero)
        isBordered = false
        title = ""
        self.target = target
        self.action = action
        sizeToFitLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        needsDisplay = true
    }

    private func attributedLabel() -> NSAttributedString {
        let isPrimary = style == .pill
        let textColor: NSColor
        if isPrimary {
            textColor = NSColor.labelColor
        } else {
            textColor = isHovered ? NSColor.labelColor : NSColor.secondaryLabelColor
        }
        return NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: isPrimary ? .medium : .regular),
            .foregroundColor: textColor
        ])
    }

    private func sizeToFitLabel() {
        let text = attributedLabel().size()
        let width = style == .pill ? text.width + 11 + 18 : text.width + 10
        setFrameSize(NSSize(width: ceil(width), height: 19))
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = attributedLabel()
        let size = text.size()

        guard style == .pill else {
            if isHovered || isHighlighted {
                NSColor.quaternaryLabelColor.withAlphaComponent(isHighlighted ? 0.18 : 0.09).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
            }
            text.draw(at: NSPoint(x: 5, y: (bounds.height - size.height) / 2))
            return
        }

        let bgAlpha: CGFloat = isHighlighted ? 0.22 : (isHovered ? 0.16 : 0.10)
        NSColor.quaternaryLabelColor.withAlphaComponent(bgAlpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        // SF Symbol rather than a hand-drawn arc: it is the system icon set, so
        // its weight and terminals match the 11pt label beside it for free.
        let glyph = NSRect(x: 8, y: (bounds.height - 11) / 2, width: 11, height: 11)
        if let symbol = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh") {
            let configured = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            ) ?? symbol
            // A template image only tints inside a control, so tint it here.
            let tint = isHovered ? NSColor.labelColor : NSColor.secondaryLabelColor
            NSImage(size: glyph.size, flipped: false) { rect in
                configured.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceAtop)
                return true
            }.draw(in: glyph)
        }

        text.draw(at: NSPoint(x: 22, y: (bounds.height - size.height) / 2))
    }
}

/// A rounded card holding one limit window's three rows.
final class ModuleView: NSView {
    static let headerHeight: CGFloat = 22
    static let rowSpacing: CGFloat = 10
    private static let insetX: CGFloat = 11
    private static let insetTop: CGFloat = 9
    private static let insetBottom: CGFloat = 11

    static func height(rows: Int) -> CGFloat {
        insetTop + headerHeight + CGFloat(rows) * UsageRowView.height
            + CGFloat(max(0, rows - 1)) * rowSpacing + insetBottom
    }

    private let title: String

    override var isFlipped: Bool { true }

    init(title: String, rows: [UsageRowView.Content], width: CGFloat) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height(rows: rows.count)))

        var y = Self.insetTop + Self.headerHeight
        for content in rows {
            let row = UsageRowView(content: content, width: width - Self.insetX * 2)
            row.setFrameOrigin(NSPoint(x: Self.insetX, y: y))
            addSubview(row)
            y += UsageRowView.height + Self.rowSpacing
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        Brand.moduleFill.setFill()
        let cardPath = NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11)
        cardPath.fill()

        // Subtle 0.5pt hairline border to give the card crisp definition on macOS
        let borderRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: 10.5, yRadius: 10.5)
        borderPath.lineWidth = 0.5
        NSColor.separatorColor.withAlphaComponent(0.12).setStroke()
        borderPath.stroke()

        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]).draw(at: NSPoint(x: Self.insetX, y: Self.insetTop))
    }
}

/// The popover's whole content.
final class PanelView: NSView {
    static let width: CGFloat = 296
    private static let padding: CGFloat = 10
    private static let moduleGap: CGFloat = 9
    private static let footerHeight: CGFloat = 22

    override var isFlipped: Bool { true }

    init(state: UsageState, target: AnyObject, refresh: Selector, quit: Selector) {
        let moduleWidth = Self.width - Self.padding * 2
        let moduleHeight = ModuleView.height(rows: 3)
        let height = Self.padding + moduleHeight + Self.moduleGap + moduleHeight
            + 6 + Self.footerHeight + Self.padding

        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))

        var y = Self.padding
        for window in [LimitWindow.fiveHour, .weekly] {
            let rows = [Provider.claude, .gemini, .antigravity3P].map { provider in
                PanelView.content(for: provider,
                                  window: window,
                                  source: provider == .claude ? state.claude : state.gemini)
            }
            let module = ModuleView(title: window.sectionTitle, rows: rows, width: moduleWidth)
            module.setFrameOrigin(NSPoint(x: Self.padding, y: y))
            addSubview(module)
            y += moduleHeight + Self.moduleGap
        }

        y += -Self.moduleGap + 6

        let freshness = NSTextField(labelWithString: PanelView.freshness(state))
        freshness.font = .systemFont(ofSize: 11)
        freshness.textColor = .secondaryLabelColor
        freshness.sizeToFit()
        freshness.setFrameOrigin(NSPoint(x: Self.padding + 4, y: y + 3))
        addSubview(freshness)

        // Quit sits as plain text and Refresh as a filled pill: the destructive
        // one should be the harder of the two to hit by accident.
        let quitButton = FooterButton(label: "Quit", style: .plain, target: target, action: quit)
        quitButton.setFrameOrigin(NSPoint(x: Self.width - Self.padding - quitButton.frame.width, y: y))
        addSubview(quitButton)

        let refreshButton = FooterButton(label: "Refresh", style: .pill, target: target, action: refresh)
        refreshButton.setFrameOrigin(NSPoint(
            x: quitButton.frame.minX - 9 - refreshButton.frame.width, y: y))
        addSubview(refreshButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Pins the popover's backdrop to its active appearance.
    ///
    /// The popover's own frame view *is* an `NSVisualEffectView`, and it ships
    /// with `state == .followsWindowActiveState`. A menu bar popover is shown
    /// before activation lands -- measured here, the window reports
    /// `isKeyWindow == false` at the moment this view is installed -- so the
    /// backdrop draws its inactive, more transparent form and only resolves once
    /// something makes the window key. That reads as "the panel is still loading"
    /// when it is in fact fully drawn. Pinning the state takes the material off
    /// the key-window path altogether, so the panel opens at its final opacity.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // From the frame view down: the effect view is the popover's frame, an
        // ancestor of `contentView`, not one of its descendants.
        var root: NSView? = window.contentView
        while let parent = root?.superview { root = parent }
        root.map(PanelView.pinEffectState)
    }

    private static func pinEffectState(_ view: NSView) {
        (view as? NSVisualEffectView)?.state = .active
        view.subviews.forEach(pinEffectState)
    }

    static func content(
        for provider: Provider,
        window: LimitWindow,
        source: Snapshot
    ) -> UsageRowView.Content {
        guard let bucket = source.bucket(provider, window) else {
            return UsageRowView.Content(
                provider: provider,
                name: provider.displayName,
                used: nil,
                detail: source.error ?? "unavailable",
                stale: true
            )
        }
        return UsageRowView.Content(
            provider: provider,
            name: provider.displayName,
            used: bucket.usedFraction,
            detail: Format.reset(bucket.resetTime, window: bucket.window),
            stale: source.error != nil
        )
    }

    static func freshness(_ state: UsageState) -> String {
        let claude = state.claude.hasData ? Format.age(state.claude.fetchedAt) : "no data"
        let gemini = state.gemini.hasData ? Format.age(state.gemini.fetchedAt) : "no data"
        return "Claude \(claude) · Gemini \(gemini)"
    }
}
