import AppKit

/// Renders the UI to PNG files without needing the screen.
///
/// `screencapture` requires Screen Recording permission this terminal doesn't
/// have, which left the visuals unverified last time. Drawing doesn't need the
/// screen though: an NSImage and an NSView can both be rasterised into a bitmap
/// offscreen, so the artwork can be inspected directly.
enum Preview {
    /// Sample states, chosen to cover every branch of the tone logic.
    private static let samples: [(label: String, used: Double?, stale: Bool)] = [
        ("0%   — untouched",      0.00, false),
        ("37%  — neutral",        0.37, false),
        ("70%  — neutral edge",   0.70, false),
        ("76%  — warning",        0.76, false),
        ("90%  — warning edge",   0.90, false),
        ("93%  — critical",       0.93, false),
        ("100% — exhausted",      1.00, false),
        ("37%  — stale",          0.37, true),
        ("no data",               nil,  true),
    ]

    static func run(directory: String) {
        let dir = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Fetch before drawing: blocking on the network inside a drawing block
        // starves the callback and every Gemini row renders "unavailable".
        let state = liveState()

        // Touching NSApplication initialises AppKit, which drawing depends on.
        _ = NSApplication.shared

        for (name, appearance) in [("light", NSAppearance(named: .aqua)!),
                                   ("dark", NSAppearance(named: .darkAqua)!)] {
            write(menuBarSheet(appearance: appearance, dark: name == "dark"),
                  to: dir.appendingPathComponent("menubar-\(name).png"))
            write(panelSheet(state, appearance: appearance, dark: name == "dark"),
                  to: dir.appendingPathComponent("panel-\(name).png"))
        }

        print("wrote previews to \(dir.path):")
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? [] {
            print("  \(file)")
        }
    }

    // MARK: - Sheets

    private static func menuBarSheet(appearance: NSAppearance, dark: Bool) -> NSBitmapImageRep {
        let rowHeight: CGFloat = 26
        let size = NSSize(width: 320, height: rowHeight * CGFloat(samples.count) + 16)

        return render(size: size, appearance: appearance) {
            background(dark: dark).setFill()
            NSRect(origin: .zero, size: size).fill()

            for (index, sample) in samples.enumerated() {
                let y = size.height - 8 - rowHeight * CGFloat(index + 1)

                let image = GaugeRenderer.statusItemImage(
                    used: sample.used,
                    stale: sample.stale
                )
                // Template images are tinted by the control that hosts them, not
                // by NSImage itself, so reproduce that here to show what the menu
                // bar will actually display.
                let drawn = image.isTemplate
                    ? tinted(image, dark ? .white : .black)
                    : image

                drawn.draw(
                    at: NSPoint(x: 16, y: y + (rowHeight - image.size.height) / 2),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )

                label(sample.label,
                      at: NSPoint(x: 130, y: y + 6),
                      color: dark ? NSColor.white.withAlphaComponent(0.55)
                                  : NSColor.black.withAlphaComponent(0.5))
            }
        }
    }

    private static func liveState() -> UsageState {
        var state = UsageState()
        state.claude = ClaudeSource().read()

        let source = GeminiSource()
        let semaphore = DispatchSemaphore(value: 0)
        source.fetch { snapshot in
            state.gemini = snapshot
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 20)
        return state
    }

    /// Renders the real `PanelView` hierarchy, so what lands in the PNG is the
    /// same code that draws the popover -- not a second description of it.
    private static func panelSheet(
        _ state: UsageState,
        appearance: NSAppearance,
        dark: Bool
    ) -> NSBitmapImageRep {
        let panel = PanelView(state: state,
                              target: NSApplication.shared,
                              refresh: #selector(NSApplication.terminate(_:)),
                              quit: #selector(NSApplication.terminate(_:)))

        // An unhosted view doesn't lay out or draw reliably; a borderless
        // offscreen window gives it the context it expects without appearing.
        let window = NSWindow(contentRect: panel.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.appearance = appearance
        // Without this, cacheDisplay backs the bitmap with the window's opaque
        // fill and the entire panel renders as a white rectangle.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = panel
        panel.layoutSubtreeIfNeeded()

        let inset: CGFloat = 22
        let size = NSSize(width: panel.frame.width + inset * 2,
                          height: panel.frame.height + inset * 2)

        return render(size: size, appearance: appearance) {
            background(dark: dark).setFill()
            NSRect(origin: .zero, size: size).fill()

            // The popover's material and shadow come from AppKit; stand in for
            // them so contrast can be judged honestly.
            let frame = NSRect(x: inset, y: inset,
                               width: panel.frame.width, height: panel.frame.height)
            NSShadow.set(dark: dark)
            (dark ? NSColor(white: 0.155, alpha: 1) : NSColor(white: 0.965, alpha: 1)).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill()
            NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0)

            // Draw the live view tree into this context rather than caching it
            // to a bitmap: cacheDisplay backs the cache with an opaque fill,
            // which buried the panel under white. This also renders at the
            // context's 3x scale instead of 1x.
            guard let context = NSGraphicsContext.current else { return }
            context.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: inset, yBy: inset)
            transform.concat()
            panel.displayIgnoringOpacity(panel.bounds, in: context)
            context.restoreGraphicsState()
        }
    }

    // MARK: - Drawing helpers

    /// Approximates the surface each element sits on, so contrast can be judged.
    private static func background(dark: Bool) -> NSColor {
        dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)
    }

    private static func label(_ text: String, at point: NSPoint, color: NSColor) {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: color
        ]).draw(at: point)
    }

    /// Approximates the popover's drop shadow so contrast can be judged.
    private static func shadowStub() {}

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let output = NSImage(size: image.size)
        output.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        output.unlockFocus()
        return output
    }

    /// Rasterises at 3x so text and hairlines are judgeable when zoomed.
    private static func render(
        size: NSSize,
        scale: CGFloat = 3,
        appearance: NSAppearance,
        _ body: () -> Void
    ) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance { body() }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}

private extension NSShadow {
    static func set(dark: Bool) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = dark ? 26 : 20
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.25)
        shadow.set()
    }
}
