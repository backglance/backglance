import SwiftUI

// MARK: - AppIconResolverKey

/// Maps a bundle id to a cached PNG on disk.
///
/// `AppIconView` cannot resolve this itself: the cache is warmed by
/// `EnrichmentService` in `BackglanceCapture`, and this package never imports
/// that module (see DEVELOPMENT_GUIDE.md, "Dependency direction"). Routing the
/// lookup through the environment lets the app shell wire the real cache in
/// while previews and tests default to a resolver that always returns `nil`,
/// which `AppIconView` already renders sensibly as the fallback glyph.
public struct AppIconResolverKey: EnvironmentKey {
    public static let defaultValue: @Sendable (String) -> URL? = { _ in nil }
}

public extension EnvironmentValues {
    /// Maps a bundle id to a cached PNG on disk. The app shell wires this to the
    /// capture layer's icon cache; previews and tests leave it returning nil.
    var appIconResolver: @Sendable (String) -> URL? {
        get { self[AppIconResolverKey.self] }
        set { self[AppIconResolverKey.self] = newValue }
    }
}

// MARK: - AppIconView

/// One app's icon, resolved from the on-disk cache — never `NSWorkspace`.
///
/// docs/features/TIMELINE.md#performance calls this out explicitly: querying
/// `NSWorkspace` per row is what makes a two-hundred-row timeline stutter.
/// `EnrichmentService` resolves and caches each app's icon once, at capture
/// time; this view only ever reads that cache through ``AppIconResolverKey``.
///
/// Decoding a PNG is not free either, so it happens once per `bundleID` — held
/// in `@State` and reloaded in `.task(id:)` — rather than on every redraw the
/// row's selection or read state triggers.
public struct AppIconView: View {
    // MARK: Lifecycle

    public init(bundleID: String?) {
        self.bundleID = bundleID
    }

    // MARK: Public

    public let bundleID: String?

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // No cached icon yet, no bundle id, or the resolver has nothing —
                // a neutral placeholder rather than leaving the row's leading
                // edge blank while capture warms the cache.
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        // The row's accessibility label already names the app; a second
        // announcement of the icon would just repeat it for VoiceOver.
        .accessibilityHidden(true)
        .task(id: bundleID) {
            await load()
        }
    }

    // MARK: Private

    @Environment(\.appIconResolver)
    private var resolveIcon
    @State private var image: NSImage?

    private func load() async {
        image = nil
        guard let bundleID, let url = resolveIcon(bundleID) else {
            return
        }
        image = NSImage(contentsOf: url)
    }
}

// MARK: - Previews

#Preview {
    HStack(spacing: 12) {
        AppIconView(bundleID: "com.apple.MobileSMS")
            .frame(width: 20, height: 20)
        AppIconView(bundleID: nil)
            .frame(width: 20, height: 20)
    }
    .padding()
}
