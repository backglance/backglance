import BackglanceCore
import BackglanceUI
import SwiftUI

// MARK: - MenuBarPopoverView

/// The popover's contents: a search field, the timeline (or its results), and a
/// footer that appears only when capture has something to say.
///
/// Everything structural is shared with the full window — both render the same
/// `TimelineView` off the same store, so the two can never disagree about what
/// is archived. What differs is chrome and size: this one is fixed at
/// 380 × 520 and shows the smallest set of controls that makes a glance useful
/// (docs/features/TIMELINE.md#menubarpopoverview).
///
/// Search replaces the timeline rather than sitting beside it. A popover this
/// size cannot show both without showing neither properly, and a search with
/// results is not a moment when the user also wants to browse.
struct MenuBarPopoverView: View {
    // MARK: Internal

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            toolbar
            Divider()

            SearchBar(model: search, indexProgress: searchService?.indexProgress) {
                actions.dismiss?()
            }
            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: presenter?.hasDigest)

            // Only when capture is not simply running: a permanent status strip
            // in a 520-point-tall popover is 6% of the timeline spent saying
            // "everything is fine".
            if store.captureState.needsAttention {
                Divider()
                CaptureStatusBanner(state: store.captureState)
            }
        }
        .frame(width: BackglanceUI.popoverSize.width, height: BackglanceUI.popoverSize.height)
        .task(id: search.hits.map(\.notificationID)) {
            await store.loadSearchItems(for: search.hits.map(\.notificationID))
        }
    }

    // MARK: Private

    @Environment(TimelineStore.self)
    private var store

    @Environment(SearchViewModel.self)
    private var search

    @Environment(\.timelineActions)
    private var actions

    /// Optional so a preview — and any host that has no archive to look a digest up in —
    /// simply renders the timeline.
    @Environment(DigestPresenter.self)
    private var presenter: DigestPresenter?

    /// Present only in the app; a preview leaves it nil and simply shows no
    /// indexing progress.
    @Environment(\.searchService)
    private var searchService

    /// Reduce Motion drops the card's slide-in — docs/reference/ACCESSIBILITY.md#reduced-motion.
    /// The digest still appears and still goes away on dismiss; it just does not travel to
    /// get there, which matters more here than elsewhere because the card arrives
    /// unprompted, on an open the user began for some other reason.
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @ViewBuilder private var content: some View {
        // The digest takes the whole surface while it is up. A 380 × 520 popover cannot
        // show a summary *and* the timeline it summarises without shortchanging both, and
        // the card's two exits — "Open timeline at this point" and dismiss — are the two
        // things someone reading it wants next anyway.
        if let digest = presenter?.current, !search.hasQuery {
            DigestView(model: digest)
                .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
        } else if search.hasQuery {
            if search.hits.isEmpty {
                SearchEmptyState(kind: search.emptyStateKind, onClearFilters: search.clear)
            } else {
                SearchResultsList(
                    hits: search.hits,
                    rows: store.searchItems,
                    mode: store.viewMode,
                    selectedID: store.selectedID,
                    onOpen: store.open
                )
            }
        } else {
            TimelineView()
        }
    }

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
                Divider()
                Button(String(localized: "Open Full Window")) {
                    actions.openWindow?()
                }
                .disabled(actions.openWindow == nil)
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

// MARK: - SearchServiceKey

/// The app's search service, where a view needs more than `SearchRunning` —
/// today only the indexing progress the bar draws.
struct SearchServiceKey: EnvironmentKey {
    static let defaultValue: SearchService? = nil
}

extension EnvironmentValues {
    var searchService: SearchService? {
        get { self[SearchServiceKey.self] }
        set { self[SearchServiceKey.self] = newValue }
    }
}
