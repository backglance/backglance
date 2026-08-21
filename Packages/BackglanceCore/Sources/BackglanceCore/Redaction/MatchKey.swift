import Foundation

public extension String {
    /// A locale-neutral, case- and diacritic-insensitive key for internal matching.
    ///
    /// "İstanbul", "ISTANBUL" and "istanbul" all produce "istanbul", and "doğrulama"
    /// matches "dogrulama" — which is what someone typing without a Turkish keyboard
    /// produces, and what a sender may well have sent.
    ///
    /// 🔒 The locale-neutral part is not a detail. `lowercased(with:)` in a Turkish locale
    /// maps "I" to "ı", so a Mac set to Turkish would silently stop matching the keyword
    /// "PIN" — a redaction rule that works everywhere except on the machines whose
    /// language it was written for. Every internal match path uses this; only user-facing
    /// *sort* order is allowed to be locale-aware
    /// (docs/reference/INTERNATIONALIZATION.md#the-turkish-locale-rule).
    var matchKey: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            // `lowercased()` with no argument is locale-independent, unlike `lowercased(with:)`.
            .lowercased()
    }
}
