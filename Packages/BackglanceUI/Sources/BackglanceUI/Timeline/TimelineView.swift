import Foundation
import SwiftUI

// MARK: - TimelineView

/// The scroll container that turns `TimelineStore.sections` into pixels.
///
/// This is the view described in docs/features/TIMELINE.md#timelineview-and-timelinesection:
/// a `ScrollViewReader` around a `LazyVStack` with pinned day headers, an
/// `ArchiveHealthBanner` for a failed read, and one of the four
/// `EmptyStateView` kinds when there is nothing to draw. Both hosts — the
/// popover and the full window — render the same instance
/// (docs/features/TIMELINE.md#architecture); only their chrome differs, which
/// is why this view has no toolbar, no search field and no footer of its own.
public struct TimelineView: View {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public var body: some View {
        VStack(spacing: 0) {
            // A failed read is a banner, never a modal and never a crash
            // (docs/features/TIMELINE.md#edge-cases-and-error-handling):
            // whatever `store.sections` already holds keeps rendering
            // underneath it.
            if let message = store.loadError {
                ArchiveHealthBanner(message: message) {
                    store.retry()
                }
            }

            if store.sections.isEmpty {
                // `onGrantAccess`/`onResume` are left unwired: only the app
                // shell knows how to open System Settings or resume capture,
                // and this view has no business inventing that.
                EmptyStateView(kind: store.emptyStateKind, onClearFilters: clearFilters)
            } else {
                timeline
            }
        }
        .onKeyPress(.upArrow) {
            store.moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            store.moveSelection(1)
            return .handled
        }
        .onKeyPress(.return) {
            guard let id = store.selectedID else {
                return .ignored
            }
            store.open(id)
            return .handled
        }
        // Space peeks: the selected row expands to detailed and back, without
        // changing what the surface remembers for next time.
        .onKeyPress(.space) {
            store.viewMode = store.viewMode == .compact ? .detailed : .compact
            return .handled
        }
        .onKeyPress(.escape) {
            guard let dismiss = actions.dismiss else {
                return .ignored
            }
            dismiss()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            // ⌘↩ hands the timeline to the full window. Checked here rather
            // than as a `keyboardShortcut` so the plain Return above keeps
            // working when there is no window to open.
            guard press.modifiers.contains(.command), let openWindow = actions.openWindow else {
                return .ignored
            }
            openWindow()
            return .handled
        }
        .focusable()
        .focusEffectDisabled()
        .task(id: store.sections.count) {
            // The popover opens straight into the list with the first unread
            // row selected, so ↓ moves rather than merely starting.
            store.selectFirstUnreadIfNeeded()
        }
    }

    // MARK: Private

    @Environment(TimelineStore.self)
    private var store

    @Environment(\.timelineActions)
    private var actions

    /// Which days' collapsed "Muted (n)" group is currently expanded. Keyed
    /// by `TimelineSection.Model.id` (the day), not by any one notification,
    /// so scrolling a muted row off screen and back does not re-collapse it.
    @State private var expandedMutedDays: Set<Date> = []

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(store.sections) { section in
                        Section {
                            TimelineSectionSlots(
                                section: section,
                                mode: store.viewMode,
                                isMutedExpanded: expandedMutedDays.contains(section.id),
                                onToggleMuted: { toggleMuted(section.id) },
                                onOpen: { store.open($0) },
                                onRowAppear: { store.rowBecameVisible($0) },
                                onRowDisappear: { store.rowBecameHidden($0) }
                            )
                        } header: {
                            DayHeader(title: section.title)
                        }
                    }

                    if store.hasMorePages {
                        PageLoadingSentinel()
                            .task { await store.loadNextPage() }
                    }
                }
            }
            // Keeps the keyboard selection on screen as ↑/↓ moves it,
            // including across a page boundary that just loaded.
            .onChange(of: store.selectedID) { _, id in
                if let id {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    /// Passed by name rather than as a closure literal: SwiftLint reads a
    /// trailing-position closure argument as a missed trailing closure, and a
    /// trailing closure here would bind to the wrong parameter.
    private func clearFilters() {
        store.clearFilters()
    }

    private func toggleMuted(_ day: Date) {
        if expandedMutedDays.contains(day) {
            expandedMutedDays.remove(day)
        } else {
            expandedMutedDays.insert(day)
        }
    }
}

// MARK: - TimelineSectionSlots

/// Draws one day's `slots`, plus its muted rows when that day is expanded.
///
/// Factored out of `TimelineView` for two reasons: it keeps `timeline`
/// readable, and — because it takes plain values and closures rather than
/// `@Environment(TimelineStore.self)` — it is what makes a `#Preview` possible
/// without constructing an `Archive` (docs/features/TIMELINE.md#testing-approach
/// takes the same view of grouping: keep the store-free part store-free).
///
/// The muted header is always the last slot in a day
/// (`TimelineStore.buildSections`), so appending the expanded rows after the
/// slot loop is what "immediately after its muted header" means in practice.
private struct TimelineSectionSlots: View {
    // MARK: Internal

    let section: TimelineSection.Model
    let mode: TimelineViewMode
    let isMutedExpanded: Bool
    let onToggleMuted: () -> Void
    let onOpen: (Int64) -> Void
    let onRowAppear: (Int64) -> Void
    let onRowDisappear: (Int64) -> Void

    var body: some View {
        Group {
            ForEach(section.slots) { slot in
                switch slot {
                case .divider:
                    UnreadDivider()

                case let .appHeader(group):
                    // `AppGroupHeader` itself only fires `onToggle` for the
                    // muted group, so handing it the same closure for every
                    // header here is safe: a plain by-app header stays inert.
                    AppGroupHeader(group: group, isExpanded: isMutedExpanded, onToggle: onToggleMuted)

                case let .row(item):
                    row(for: item)
                }
            }

            if isMutedExpanded {
                ForEach(section.mutedItems) { item in
                    row(for: item)
                }
            }
        }
    }

    // MARK: Private

    private func row(for item: TimelineItem) -> some View {
        NotificationRow(item: item, mode: mode, onOpen: onOpen)
            .id(item.id)
            .onAppear { onRowAppear(item.id) }
            .onDisappear { onRowDisappear(item.id) }
    }
}

// MARK: - PageLoadingSentinel

/// A reachable, near-invisible trigger for `loadNextPage()`.
///
/// Fixed height so `LazyVStack` always lays it out — an intrinsically-sized
/// empty view can end up with zero height and never actually enter the
/// viewport, which would mean pagination that only fires by accident.
private struct PageLoadingSentinel: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
    }
}

// MARK: - Previews

#Preview("Sections") {
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
            ForEach(PreviewData.sections) { section in
                Section {
                    TimelineSectionSlots(
                        section: section,
                        mode: .compact,
                        isMutedExpanded: true,
                        onToggleMuted: {},
                        onOpen: { _ in },
                        onRowAppear: { _ in },
                        onRowDisappear: { _ in }
                    )
                } header: {
                    DayHeader(title: section.title)
                }
            }
        }
    }
    .frame(width: 380, height: 520)
}
