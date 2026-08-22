import AppKit
import Foundation

// MARK: - AppNameSource

/// Where an app's human-readable name comes from.
///
/// A protocol for the same reason ``AppIconSource`` is one: the timeline's app names must
/// be testable without installing applications, and a Mac where the app has been
/// uninstalled is an ordinary `nil` rather than a special case.
public protocol AppNameSource: Sendable {
    /// The localized name for `bundleID`, or `nil` if the app cannot be resolved.
    func name(forBundleID bundleID: String) -> String?
}

// MARK: - WorkspaceAppNameSource

/// The real source: whatever the installed application bundle calls itself.
///
/// > 🔒 Reads only the application bundle, through public API. No notification content is
/// > involved in resolving a name — the bundle id is the whole input, and the answer is
/// > the same for every user with that app installed.
public struct WorkspaceAppNameSource: AppNameSource {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    /// Prefers what the bundle says about itself over what the file is called.
    ///
    /// The localized `Info.plist` first, because that is the name the user sees
    /// everywhere else in the system in their own language; then the unlocalized keys;
    /// then Finder's display name, which is the file name with `.app` stripped. An app
    /// that resolves to a URL but carries none of those is not worth a name at all — the
    /// caller keeps the bundle id, which is at least true.
    public func name(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        if let bundle = Bundle(url: url) {
            let keys = ["CFBundleDisplayName", "CFBundleName"]
            let candidates = keys.compactMap { bundle.localizedInfoDictionary?[$0] as? String }
                + keys.compactMap { bundle.object(forInfoDictionaryKey: $0) as? String }
            if let name = candidates.first(where: { $0.isEmpty == false }) {
                return name
            }
        }

        let finderName = FileManager.default.displayName(atPath: url.path)
        return finderName.isEmpty ? nil : finderName
    }
}
