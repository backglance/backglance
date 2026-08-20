import Foundation

// MARK: - HighlightColor

/// The colour token a `highlight` (or, in v1.x, `regex`) rule paints its rows with.
///
/// A token rather than a colour value: `BackglanceCore` has no opinion about
/// rendering, and the same five names have to survive a rules export written on
/// one Mac and imported on another. Resolution to an actual colour happens in
/// `BackglanceUI`, where each token maps to a system colour that already
/// carries its light, dark and increased-contrast variants.
///
/// The raw values are the vocabulary stored in `rules.color`, so they are part of
/// the archive format — see docs/features/RULES.md#rule-kinds.
public enum HighlightColor: String, Codable, CaseIterable, Hashable, Sendable {
    case amber
    case red
    case green
    case blue
    case purple
}
