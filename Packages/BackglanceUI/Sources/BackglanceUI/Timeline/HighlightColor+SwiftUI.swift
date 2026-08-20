import BackglanceCore
import SwiftUI

// MARK: - HighlightColor + SwiftUI

public extension HighlightColor {
    /// The opacity a highlight tint fills a row at.
    ///
    /// Not a free parameter. docs/reference/ACCESSIBILITY.md caps it at the
    /// value where `Color.primary` over the tint still clears WCAG AA, and
    /// `HighlightContrastTests` is what holds it to that promise — so raising
    /// it means re-running that test, not editing it.
    static var tintOpacity: Double {
        0.12
    }

    /// The colour a highlight rule's row tint actually paints with.
    ///
    /// System colours rather than an asset catalog: this package ships no
    /// resource bundle — see `AppIconView.swift`'s note on why `BackglanceUI`
    /// stays free of one — so there is nothing for a `bundle: .module` lookup
    /// to resolve against, and `.orange`, `.red`, `.green`, `.blue` and
    /// `.purple` already carry the light, dark and increased-contrast variants
    /// a hand-rolled catalog would otherwise have to reproduce one entry at a
    /// time (docs/features/RULES.md#rule-kinds).
    var swiftUIColor: Color {
        switch self {
        case .amber: .orange
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }
}
