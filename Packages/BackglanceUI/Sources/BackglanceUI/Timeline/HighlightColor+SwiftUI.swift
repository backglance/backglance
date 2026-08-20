import BackglanceCore
import SwiftUI

// MARK: - HighlightColor + SwiftUI

public extension HighlightColor {
    /// The colour a highlight rule's row tint actually paints with.
    ///
    /// docs/features/RULES.md specifies an asset-catalog colour per token
    /// (`Color("Highlight/\(rawValue)", bundle: .module)`), but this package
    /// ships no resource bundle — see `AppIconView.swift`'s note on why
    /// `BackglanceUI` stays free of one — so there is no catalog for a
    /// `bundle: .module` lookup to resolve against. The system colours below
    /// are the deliberate substitute: `.orange`, `.red`, `.green`, `.blue` and
    /// `.purple` already ship the light, dark and increased-contrast variants
    /// a hand-rolled catalog would otherwise have to reproduce one entry at a
    /// time, for no gain over what AppKit already maintains.
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
