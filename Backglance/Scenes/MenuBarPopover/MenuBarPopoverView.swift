import BackglanceCore
import BackglanceUI
import SwiftUI

// MARK: - MenuBarPopoverView

/// The popover's contents: a thin toolbar, the timeline, and a footer that
/// appears only when capture has something to say.
///
/// Everything structural is shared with the full window — both render the same
/// `TimelineView` off the same store, so the two can never disagree about what
/// is archived. What differs is chrome and size: this one is fixed at
/// 380 × 520 and shows the smallest set of controls that makes a glance useful
/// (docs/features/TIMELINE.md#menubarpopoverview).
struct MenuBarPopoverView: View {
    // MARK: Internal

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            toolbar
            Divider()

            TimelineView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Only when capture is not simply running: a permanent status strip
            // in a 520-point-tall popover is 6% of the timeline spent saying
            // "everything is fine".
            if store.captureState.needsAttention {
                Divider()
                CaptureStatusBanner(state: store.captureState)
            }
        }
        .frame(width: BackglanceUI.popoverSize.width, height: BackglanceUI.popoverSize.height)
    }

    // MARK: Private

    @Environment(TimelineStore.self)
    private var store

    private var toolbar: some View {
        @Bindable var store = store

        return HStack(spacing: 8) {
            Text("Backglance")
                .font(.headline)

            Spacer(minLength: 8)

            Picker(String(localized: "View mode"), selection: $store.viewMode) {
                Image(systemName: "list.bullet").tag(TimelineViewMode.compact)
                Image(systemName: "list.bullet.rectangle").tag(TimelineViewMode.detailed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76)

            Menu {
                Toggle(String(localized: "Group by app"), isOn: $store.groupByApp)
                Button(String(localized: "Mark All as Read")) {
                    store.markAllRead()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(String(localized: "Timeline options"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
