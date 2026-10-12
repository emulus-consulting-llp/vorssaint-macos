import AppKit

/// Per-provider colour and mark.
///
/// The colour model has two channels that must not collide:
///   the BAR says *who*   — Claude clay, Gemini blue, Antigravity grey
///   the PERCENT says *how urgent* — amber past 70%, red past 90%
/// Keeping them separate means brand colour never has to be given up to show a
/// warning: Gemini reads blue at 81% with an amber number.
enum Brand {
    /// Resolves per appearance, so AppKit swaps them on a theme change without
    /// the views having to observe anything.
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// The card surface inside the popover: a white veil over the material in
    /// both themes, so a module always lifts off its background rather than
    /// sinking into it.
    static var moduleFill: NSColor {
        dynamic(light: NSColor(white: 1, alpha: 0.62),
                dark: NSColor(white: 1, alpha: 0.075))
    }

    /// The tile behind a provider mark. Neutral by design — three coloured
    /// tiles would compete with the bars they sit next to.
    static var tileFill: NSColor {
        dynamic(light: NSColor(white: 0, alpha: 0.06),
                dark: NSColor(white: 1, alpha: 0.10))
    }

    static func color(_ provider: Provider) -> NSColor {
        switch provider {
        case .claude:
            return dynamic(light: NSColor(srgbRed: 0.784, green: 0.384, blue: 0.247, alpha: 1),
                           dark: NSColor(srgbRed: 0.910, green: 0.592, blue: 0.478, alpha: 1))
        case .gemini:
            return dynamic(light: NSColor(srgbRed: 0.231, green: 0.471, blue: 0.906, alpha: 1),
                           dark: NSColor(srgbRed: 0.478, green: 0.659, blue: 0.973, alpha: 1))
        case .antigravity3P:
            return dynamic(light: NSColor(srgbRed: 0.373, green: 0.388, blue: 0.408, alpha: 1),
                           dark: NSColor(srgbRed: 0.604, green: 0.627, blue: 0.651, alpha: 1))
        }
    }

    /// Draws the official brand mark in `rect`.
    ///
    /// Claude and Gemini marks maintain their brand colors in both light and dark modes.
    /// Antigravity is rendered in black for light mode and inverted to white for dark mode.
    static func drawMark(_ provider: Provider, in rect: NSRect, alpha: CGFloat = 1.0) {
        NSGraphicsContext.current?.imageInterpolation = .high

        let image: NSImage
        switch provider {
        case .claude:
            image = LogoAssets.claude

        case .gemini:
            image = LogoAssets.gemini

        case .antigravity3P:
            let appearance = NSAppearance.currentDrawing()
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            image = isDark ? LogoAssets.antigravityWhite : LogoAssets.antigravityBlack
        }

        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
    }
}
