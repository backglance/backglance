import SwiftUI

/// Module marker for `BackglanceUI`.
///
/// The shared SwiftUI views (timeline, digest, search, settings) land in Phase 2.
public enum BackglanceUI {
    /// Size of the menu bar popover, in points.
    ///
    /// `StatusItemController` sets `NSPopover.contentSize` from this, so the popover
    /// and the SwiftUI content agree on a size without either measuring the other.
    public static let popoverSize = CGSize(width: 380, height: 520)
}
