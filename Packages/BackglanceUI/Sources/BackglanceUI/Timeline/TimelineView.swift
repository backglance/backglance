import BackglanceCore
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
        // Every other shortcut in docs/features/ACTIONS.md's table and
        // docs/features/TIMELINE.md's own — see `TimelineKeyboardShortcuts`'
        // doc comment (`TimelineView+Keyboard.swift`) for why this is a
        // `ViewModifier` in its own file rather than a longer `.onKeyPress`
        // chain here.
        .modifier(TimelineKeyboardShortcuts(exportIDs: $exportIDs, actionError: $actionError))
        .focusable()
        .focusEffectDisabled()
        .task(id: store.sections.count) {
            // The popover opens straight into the list with the first unread
            // row selected, so ↓ moves rather than merely starting.
            store.selectFirstUnreadIfNeeded()
        }
        // Clears itself a few seconds after it last changed — a fresh error
        // restarts the clock rather than racing the one already running,
        // which is exactly what keying this `.task` on `actionError` buys:
        // SwiftUI cancels and restarts the task whenever its `id` changes,
        // the same trick `NotificationActionHandler`'s undo toast expiry
        // implements by hand with a `Task` it cancels itself.
        .task(id: actionError) {
            guard actionError != nil else {
                return
            }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else {
                return
            }
            actionError = nil
        }
        // Same idiom as `actionError` just above, keyed on `TimelineMessage.id` rather
        // than the message itself: two different `backglance://open?id=` links that
        // both land on "Not in the archive" are still two separate tasks, each
        // restarting its own four-second clock rather than the second toast inheriting
        // whatever was left of the first's.
        .task(id: store.message?.id) {
            guard store.message != nil else {
                return
            }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else {
                return
            }
            store.clearMessage()
        }
        .sheet(isPresented: isExportSheetPresented) {
            if let ids = exportIDs {
                exportSheet(for: ids)
            }
        }
        .overlay(alignment: .bottom) {
            // Order matters only in that both can be on screen together —
            // an export failure right after a delete would otherwise have
            // nowhere to land while the toast is still counting down. The
            // error sits above the toast so a fresh one is never hidden
            // behind it.
            VStack(spacing: 8) {
                if let message = actionError?.userMessage {
                    ActionErrorBanner(message: message)
                }
                if let handler = actionDispatcher as? NotificationActionHandler, !handler.pendingUndo.isEmpty {
                    UndoToastView(count: handler.pendingUndo.count) {
                        ActionDispatchRouting.run {
                            try handler.undoDelete()
                        } onError: {
                            actionError = $0
                        }
                    }
                }
                if let message = store.message {
                    MessageToastView(message: message.text)
                }
            }
        }
    }

    // MARK: Private

    @Environment(TimelineStore.self)
    private var store

    @Environment(\.timelineActions)
    private var actions

    /// Read by the undo toast overlay below, the same downcast
    /// `NotificationRow+ContextMenu`'s `canActivateApp` already uses to
    /// reach `pendingUndo` — see `TimelineKeyboardShortcuts.handleUndo(_:)`
    /// for the other place this same downcast happens, for ⌘Z.
    @Environment(\.actionDispatcher)
    private var actionDispatcher

    /// Which days' collapsed "Muted (n)" group is currently expanded. Keyed
    /// by `TimelineSection.Model.id` (the day), not by any one notification,
    /// so scrolling a muted row off screen and back does not re-collapse it.
    @State private var expandedMutedDays: Set<Date> = []

    /// The ids `ExportSheet` is open for, or `nil` when it is not presented.
    /// Set by ⌘E (`TimelineKeyboardShortcuts`) and by the row context menu's
    /// "Export Selection…" (`onRequestExport` below) — both funnel through
    /// this one property so there is exactly one sheet to reason about
    /// regardless of which of the two ways it was opened.
    @State private var exportIDs: [Int64]?

    /// The most recent dispatch failure worth showing inline —
    /// docs/features/ACTIONS.md's error table ("Couldn't open ‹App›",
    /// "Export failed: …", and so on), rendered by ``ActionErrorBanner``
    /// below and cleared automatically a few seconds after it last changed.
    /// Written by `NotificationRow`'s `onActionError` (a context-menu
    /// dispatch failure) and by `TimelineKeyboardShortcuts` (a keyboard
    /// dispatch failure) — the same property either way, since the error
    /// this view shows should not depend on which of the two ways the
    /// action was triggered.
    @State private var actionError: ActionError?

    /// Drives `.sheet(isPresented:)`: presented exactly while `exportIDs` is
    /// non-`nil`, and dismissing the sheet any other way (the system's own
    /// swipe/click-outside dismissal, not just `onCancel`) clears it back to
    /// `nil` through this same `Binding` rather than leaving it stale.
    private var isExportSheetPresented: Binding<Bool> {
        Binding(get: { exportIDs != nil }, set: { if !$0 {
            exportIDs = nil
        } })
    }

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
                                selectionIDs: store.selectedIDsInVisibleOrder,
                                host: store.host,
                                onToggleMuted: { toggleMuted(section.id) },
                                onOpen: { store.open($0) },
                                onRowAppear: { store.rowBecameVisible($0) },
                                onRowDisappear: { store.rowBecameHidden($0) },
                                onToggleSelect: { store.toggleSelection($0) },
                                onExtendSelect: { store.extendSelection(to: $0) },
                                onRequestExport: { exportIDs = $0 },
                                onActionError: { actionError = $0 }
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
            // `reveal(_:)`'s own scroll signal — see `ScrollRequest`'s doc comment for
            // why this cannot just piggyback on the `selectedID` case above: revealing
            // a row that was already selected changes nothing `onChange` there would
            // see, and a second `backglance://open?id=` for the same notification
            // would silently fail to re-scroll to it.
            .onChange(of: store.scrollRequest) { _, request in
                if let request {
                    proxy.scrollTo(request.rowID)
                }
            }
        }
    }

    /// docs/features/ACTIONS.md#select-and-export: the sheet only reports which
    /// format was chosen — running the save panel and the export itself is
    /// ``NotificationActionHandler/exportSelection(_:format:)``'s job, dispatched here
    /// through ``ActionDispatchRouting/runAsync(_:onError:)`` the same way
    /// `NotificationRow+ContextMenu`'s `.exportSelection` branch dispatches
    /// ``ActionDispatching/openNotification(id:)``.
    private func exportSheet(for ids: [Int64]) -> some View {
        ExportSheet(
            selectionCount: ids.count,
            onExport: { format in
                exportIDs = nil
                if let dispatcher = actionDispatcher {
                    ActionDispatchRouting.runAsync {
                        try await dispatcher.exportSelection(ids, format: format)
                    }
                    onError: {
                        actionError = $0
                    }
                }
            },
            onCancel: { exportIDs = nil }
        )
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

    /// Passed straight through to every `NotificationRow` in this section —
    /// see `NotificationRow`'s own doc comment for why it takes these as
    /// plain values instead of reaching for `TimelineStore` itself.
    let selectionIDs: [Int64]
    let host: TimelineStore.Host

    let onToggleMuted: () -> Void
    let onOpen: (Int64) -> Void
    let onRowAppear: (Int64) -> Void
    let onRowDisappear: (Int64) -> Void
    let onToggleSelect: (Int64) -> Void
    let onExtendSelect: (Int64) -> Void
    let onRequestExport: ([Int64]) -> Void
    let onActionError: (ActionError) -> Void

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
        NotificationRow(
            item: item,
            mode: mode,
            onOpen: onOpen,
            selectionIDs: selectionIDs,
            host: host,
            onToggleSelect: onToggleSelect,
            onExtendSelect: onExtendSelect,
            onRequestExport: onRequestExport,
            onActionError: onActionError
        )
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

// MARK: - ActionErrorBanner

/// The inline, non-modal message for a dispatch failure worth showing —
/// docs/features/ACTIONS.md's error table asks for exactly that, "never an
/// alert", the same instruction ``NotificationActionHandler``'s own doc
/// comment already follows for where the error is *thrown*; this is where it
/// finally becomes text. Styled after ``UndoToastView``, which is what the
/// two look like sitting in the same bottom overlay in `TimelineView.body`,
/// but with no button of its own — there is nothing here to undo, only to
/// read and then stop reading a few seconds later once `TimelineView`'s
/// `actionError` clears itself.
private struct ActionErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator)
            )
            .padding(.horizontal, 12)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("timeline.actionError")
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
                        selectionIDs: [],
                        host: .popover,
                        onToggleMuted: {},
                        onOpen: { _ in },
                        onRowAppear: { _ in },
                        onRowDisappear: { _ in },
                        onToggleSelect: { _ in },
                        onExtendSelect: { _ in },
                        onRequestExport: { _ in },
                        onActionError: { _ in }
                    )
                } header: {
                    DayHeader(title: section.title)
                }
            }
        }
    }
    .frame(width: 380, height: 520)
}
