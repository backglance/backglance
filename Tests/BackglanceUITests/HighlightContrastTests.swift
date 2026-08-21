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

    /// WCAG 1.4.11, for a graphical element carrying meaning on its own.
    static let minimumNonTextRatio = 3.0

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

    /// In increased contrast the row is not tinted at all — `NotificationRow`
    /// strokes a 2 pt border in the token colour instead. That border is the
    /// entire highlight signal there, which makes it a WCAG 1.4.11 non-text
    /// element and puts it on the hook for 3:1 against the row behind it.
    ///
    /// This can only be measured with Increase Contrast actually on, because
    /// that setting — not the appearance name — is what selects the palette
    /// the border paints with (see `standardAppearances`). With it off the
    /// test skips loudly rather than measuring the ordinary colours and
    /// calling the result increased-contrast coverage.
    ///
    /// Measured with the *ordinary* palette, amber lands at 2.31:1 and green
    /// at 2.22:1 — both under the bar. Whether that survives the real
    /// accessible palette is exactly what running this with the setting on
    /// will settle.
    func testHighlightBorderClearsNonTextContrast() throws {
        try XCTSkipUnless(
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            """
            Increase Contrast is off system-wide, so this process cannot reach the palette the \
            highlight border actually paints with — NSAppearance(named: .accessibilityHighContrastAqua) \
            reports its name as NSAppearanceNameAqua and resolves the ordinary colours. \
            Turn on System Settings ▸ Accessibility ▸ Display ▸ Increase contrast and run this test \
            again to find out whether the border clears 3:1.
            """
        )

        for appearance in Self.standardAppearances {
            for surface in Self.surfaces {
                for token in HighlightColor.allCases {
                    let measured = try measureBorder(token: token, surface: surface.color, appearance: appearance.value)

                    XCTAssertGreaterThanOrEqual(
                        measured,
                        Self.minimumNonTextRatio,
                        """
                        The \(token.rawValue) highlight border is \(String(format: "%.2f", measured)):1 \
                        against \(surface.name) in \(appearance.name) — below the WCAG 1.4.11 \
                        non-text bound (\(Self.minimumNonTextRatio):1). In increased contrast that \
                        border is the whole highlight signal, so it needs either a different colour \
                        or a companion affordance that is not colour.
                        """
                    )
                }
            }
        }
    }

    // MARK: Private

    /// Light and dark. There is no third and fourth entry here, and the
    /// reason is worth writing down because it is not what the API suggests.
    ///
    /// `NSAppearance(named: .accessibilityHighContrastAqua)` returns a
    /// perfectly good object — whose `name` is `NSAppearanceNameAqua`. The
    /// high-contrast names collapse to the plain ones unless Increase
    /// Contrast is on system-wide, so every colour resolved "in" them is
    /// simply the ordinary palette. Listing them would not extend coverage,
    /// it would double-count it under a misleading label.
    ///
    /// The palette actually follows
    /// `NSWorkspace.accessibilityDisplayShouldIncreaseContrast`, which is why
    /// `testHighlightBorderClearsNonTextContrast` reads that flag and skips
    /// rather than pretending.
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

    /// The ratio of the increased-contrast border against the row behind it.
    /// The border is stroked at full opacity, so there is nothing to
    /// composite — only the surface is resolved and compared.
    private func measureBorder(
        token: HighlightColor,
        surface: NSColor,
        appearance appearanceName: NSAppearance.Name
    ) throws -> Double {
        let appearance = try XCTUnwrap(
            NSAppearance(named: appearanceName),
            "The \(appearanceName.rawValue) appearance is unavailable, so nothing can be resolved for it."
        )
        let background = try XCTUnwrap(
            ContrastRatio.resolve(surface, in: appearance),
            "The row surface does not resolve to sRGB, so its contrast cannot be measured."
        )
        let border = try XCTUnwrap(
            ContrastRatio.resolve(NSColor(token.swiftUIColor), in: appearance),
            "The \(token.rawValue) border does not resolve to sRGB, so its contrast cannot be measured."
        )
        return ContrastRatio.ratio(border, background)
    }
}
