import AppKit
import BackglanceCore
@testable import BackglanceUI
import SwiftUI
import XCTest

/// The contrast test docs/features/RULES.md#rule-kinds promises and
/// docs/reference/ACCESSIBILITY.md#contrast specifies.
///
/// Highlight tints are the one place Backglance paints a colour of its own
/// behind text, which makes them the one place a rule can quietly render a
/// notification unreadable. `NotificationRow` fills the row with
/// `swiftUIColor.opacity(HighlightColor.tintOpacity)` and draws
/// `Color.primary` on top; what follows measures exactly that stack.
///
/// The opacity is read from the shipped constant rather than repeated here, so
/// raising the tint fails this test instead of silently passing a copy of the
/// old value.
@MainActor
final class HighlightContrastTests: XCTestCase {
    // MARK: Internal

    /// WCAG AA for body text.
    static let minimumTextRatio = 4.5

    /// Every token, over every surface a row can land on, in light and dark.
    ///
    /// The surfaces resolve to the same colour on current macOS; they are
    /// listed separately so that if a future release makes a popover's
    /// backing differ from a window's, the weaker of the two is what gets
    /// asserted rather than whichever one this test happened to name.
    func testPrimaryTextOverEveryTintClearsWCAGAA() throws {
        for appearance in Self.standardAppearances {
            for surface in Self.surfaces {
                for token in HighlightColor.allCases {
                    let measured = try measure(token: token, surface: surface.color, appearance: appearance.value)

                    XCTAssertGreaterThanOrEqual(
                        measured,
                        Self.minimumTextRatio,
                        """
                        Color.primary over the \(token.rawValue) tint is \(String(format: "%.2f", measured)):1 \
                        on \(surface.name) in \(appearance.name) — below WCAG AA (\(Self.minimumTextRatio):1). \
                        Lower HighlightColor.tintOpacity or change the token's colour; do not lower this bound.
                        """
                    )
                }
            }
        }
    }

    /// The cap has to bind on something. If the shipped opacity could be
    /// raised arbitrarily and still pass, the test above would be measuring
    /// the tint's colour rather than the cap on its strength — so this pins
    /// that a materially heavier tint would in fact fail somewhere.
    func testTheOpacityCapIsWhatKeepsTheTintLegible() throws {
        let excessive = 0.85
        var worst = Double.infinity

        for appearance in Self.standardAppearances {
            for token in HighlightColor.allCases {
                let measured = try measure(
                    token: token,
                    surface: NSColor.windowBackgroundColor,
                    appearance: appearance.value,
                    opacity: excessive
                )
                worst = min(worst, measured)
            }
        }

        XCTAssertLessThan(
            worst,
            Self.minimumTextRatio,
            """
            At \(excessive) opacity every token still cleared AA, so the shipped cap \
            is not what is protecting legibility.
            """
        )
    }

    /// A guard on the constant itself: a value outside 0…1 is not a tint, and
    /// 0 would silently disable highlighting altogether while every ratio
    /// above still passed.
    func testTheShippedOpacityIsAMeaningfulTint() {
        XCTAssertGreaterThan(HighlightColor.tintOpacity, 0)
        XCTAssertLessThanOrEqual(HighlightColor.tintOpacity, 1)
    }

    // MARK: Private

    /// Only the two appearances a unit test can actually resolve.
    ///
    /// `NSAppearance(named: .accessibilityHighContrastAqua)` exists, but on
    /// current macOS it resolves to the same palette as `.aqua` — the
    /// increase-contrast variants follow the system-wide setting
    /// (`NSWorkspace.accessibilityDisplayShouldIncreaseContrast`), which a
    /// test process cannot turn on. Asserting against those names would
    /// therefore re-measure the normal palette under a different label and
    /// report coverage that does not exist.
    ///
    /// It costs less than it looks like: in increased contrast
    /// `NotificationRow` does not fill the row at all, it strokes a border,
    /// so there is no `Color.primary`-over-tint stack there to measure.
    private static let standardAppearances: [(name: String, value: NSAppearance.Name)] = [
        ("light", .aqua),
        ("dark", .darkAqua),
    ]

    private static let surfaces: [(name: String, color: NSColor)] = [
        ("windowBackground", .windowBackgroundColor),
        ("controlBackground", .controlBackgroundColor),
        ("textBackground", .textBackgroundColor),
    ]

    /// The ratio of `Color.primary` against the tinted row it sits on.
    private func measure(
        token: HighlightColor,
        surface: NSColor,
        appearance appearanceName: NSAppearance.Name,
        opacity: Double? = nil
    ) throws -> Double {
        let appearance = try XCTUnwrap(
            NSAppearance(named: appearanceName),
            "The \(appearanceName.rawValue) appearance is unavailable, so nothing can be resolved for it."
        )
        let background = try XCTUnwrap(
            ContrastRatio.resolve(surface, in: appearance),
            "The row surface does not resolve to sRGB, so its contrast cannot be measured."
        )
        let tint = try XCTUnwrap(
            ContrastRatio.resolve(NSColor(token.swiftUIColor), in: appearance),
            "The \(token.rawValue) tint does not resolve to sRGB, so its contrast cannot be measured."
        )
        let label = try XCTUnwrap(
            ContrastRatio.resolve(NSColor(Color.primary), in: appearance),
            "Color.primary does not resolve to sRGB, so its contrast cannot be measured."
        )

        // The row as it is actually painted: tint over the surface, then the
        // label — itself partly transparent — over that.
        let tinted = ContrastRatio.composite(tint, over: background, opacity: opacity ?? HighlightColor.tintOpacity)
        let text = ContrastRatio.composite(label, over: tinted)
        return ContrastRatio.ratio(text, tinted)
    }
}
