import SwiftUI

// MARK: - ToastPresentation

/// The chrome every bottom-of-timeline toast shares: the material capsule, the
/// hairline border, the slide-in-from-the-bottom transition (or a plain fade under
/// Reduce Motion), and the accessibility container.
///
/// Factored out of ``UndoToastView`` — which drew all of this by hand before
/// ``MessageToastView`` needed the same look — so the two never drift apart one tweak
/// at a time. Takes its content as a `@ViewBuilder` rather than a `String` because
/// ``UndoToastView`` needs a trailing "Undo" button this generic has no business
/// knowing about: a `Text` + optional-button parameter pair would just be this view's
/// body, rewritten by hand at every call site instead of once, here.
struct ToastPresentation<Content: View>: View {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - accessibilityIdentifier: what a UI test finds this toast by.
    ///   - accessibilityChildren: `.combine` reads as one VoiceOver announcement —
    ///     right for ``MessageToastView``, which has nothing interactive inside.
    ///     `.contain` leaves each child separately reachable — right for
    ///     ``UndoToastView``, whose "Undo" button needs its own stop.
    init(
        accessibilityIdentifier: String,
        accessibilityChildren: AccessibilityChildBehavior = .contain,
        @ViewBuilder content: () -> Content
    ) {
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityChildren = accessibilityChildren
        self.content = content()
    }

    // MARK: Internal

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .bottom)
        // A move-in reads as the toast arriving *from* whatever triggered it, which is
        // the point of a toast at all; Reduce Motion collapses that to a plain
        // appear/disappear, per docs/reference/ACCESSIBILITY.md#reduced-motion — the
        // same trade `AppGroupHeader`'s chevron makes for its rotation.
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: accessibilityChildren)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    // MARK: Private

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    private let accessibilityIdentifier: String
    private let accessibilityChildren: AccessibilityChildBehavior
    private let content: Content
}
