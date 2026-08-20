import AppKit
import SwiftUI

// MARK: - ContrastRatio

/// WCAG contrast arithmetic over colours resolved for a named appearance.
///
/// Test-only. Nothing in the app computes a contrast ratio at runtime; this
/// exists so the highlight tints can be *checked* against the promise in
/// docs/reference/ACCESSIBILITY.md#contrast rather than eyeballed.
///
/// The one subtlety is where the resolving happens. A system colour like
/// `NSColor.labelColor` or `.systemOrange` is a catalog entry, not an RGB
/// triple: asking it for components outside a drawing appearance gives you
/// whichever variant happens to be current. Every lookup here therefore runs
/// inside `performAsCurrentDrawingAppearance`, and every comparison is done in
/// sRGB so the numbers mean the same thing across displays.
enum ContrastRatio {
    // MARK: Internal

    /// A resolved, appearance-independent colour.
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    /// Resolves a colour to sRGB components under `appearance`.
    ///
    /// Returns `nil` only if the colour cannot be expressed in sRGB at all —
    /// a pattern or catalog image colour. Callers treat that as a test
    /// failure rather than skipping it, because a highlight tint that cannot
    /// be measured cannot be trusted either.
    static func resolve(_ color: NSColor, in appearance: NSAppearance) -> RGB? {
        var resolved: RGB?
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = color.usingColorSpace(.sRGB) else {
                return
            }
            resolved = RGB(
                red: Double(srgb.redComponent),
                green: Double(srgb.greenComponent),
                blue: Double(srgb.blueComponent),
                alpha: Double(srgb.alphaComponent)
            )
        }
        return resolved
    }

    /// Paints `top` over `bottom`, optionally overriding `top`'s own alpha —
    /// which is how a `.opacity(_:)` modifier composites.
    ///
    /// Blending happens on the gamma-encoded components, matching Core
    /// Graphics rather than a linear-light compositor.
    static func composite(_ top: RGB, over bottom: RGB, opacity: Double? = nil) -> RGB {
        let alpha = opacity ?? top.alpha
        return RGB(
            red: top.red * alpha + bottom.red * (1 - alpha),
            green: top.green * alpha + bottom.green * (1 - alpha),
            blue: top.blue * alpha + bottom.blue * (1 - alpha),
            alpha: 1
        )
    }

    /// The WCAG 2.1 contrast ratio between two opaque colours, from 1 (same
    /// colour) to 21 (black on white).
    static func ratio(_ one: RGB, _ other: RGB) -> Double {
        let first = relativeLuminance(one)
        let second = relativeLuminance(other)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    // MARK: Private

    private static func relativeLuminance(_ color: RGB) -> Double {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    private static func linear(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
}
