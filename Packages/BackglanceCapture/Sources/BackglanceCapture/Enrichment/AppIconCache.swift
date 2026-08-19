import AppKit
import BackglanceCore
import Foundation

// MARK: - AppIconSource

/// Where an app's icon comes from.
///
/// A protocol rather than a direct `NSWorkspace` call so that the cache can be tested
/// without installing applications, and so a Mac where an app has been uninstalled is an
/// ordinary `nil` rather than a special case.
public protocol AppIconSource: Sendable {
    /// PNG bytes for `bundleID`'s icon, or `nil` if the app is not installed.
    func iconPNG(forBundleID bundleID: String) -> Data?
}

// MARK: - WorkspaceIconSource

/// The real source: whatever icon Launch Services has for the installed app.
///
/// > 🔒 Reads only the application bundle, through public API. No notification content
/// > is involved in resolving an icon — the bundle id is the whole input.
public struct WorkspaceIconSource: AppIconSource {
    // MARK: Lifecycle

    public init(size: CGFloat = 64) {
        self.size = size
    }

    // MARK: Public

    /// The square edge the icon is rendered at. 64 points covers the timeline row and
    /// the popover at 2× without keeping a 1024-point original per app.
    public let size: CGFloat

    public func iconPNG(forBundleID bundleID: String) -> Data? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: size, height: size)

        guard
            let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}

// MARK: - AppIconCache

/// The on-disk icon cache under `Application Support/Backglance/icons/`.
///
/// Icons are cached because resolving one means asking Launch Services about an
/// application bundle, and the timeline draws dozens of rows at a time. They are cached
/// *on disk* rather than in memory because the menu bar app is long-lived but its windows
/// are not: the popover opens, draws, and closes, and re-resolving every icon each time
/// would make opening it visibly slower on a Mac with many notifying apps.
///
/// > 🔒 Nothing here touches notification content. The cache is keyed by bundle id, the
/// > file name is sanitised so an odd identifier cannot write outside the directory, and
/// > the contents are an application's own icon — public, and identical for every user
/// > with that app installed.
public struct AppIconCache: Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - directory: where PNGs live. Defaults to the app's icon cache.
    ///   - source: where icons come from when they are not cached yet.
    public init(
        directory: URL = ArchivePaths.iconsDirectory,
        source: any AppIconSource = WorkspaceIconSource()
    ) {
        self.directory = directory
        self.source = source
    }

    // MARK: Public

    public let directory: URL

    /// The cached PNG for `bundleID`, or `nil` if it has not been cached.
    public func cachedURL(forBundleID bundleID: String) -> URL? {
        let url = fileURL(forBundleID: bundleID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Caches `bundleID`'s icon if it is not cached already, and reports where it is.
    ///
    /// Every failure is `nil`: an app that is not installed any more, a Launch Services
    /// lookup that returns nothing, a disk that will not accept the write. A missing icon
    /// costs the timeline a generic glyph, and is never worth failing a capture over.
    @discardableResult
    public func ensureIcon(forBundleID bundleID: String) -> URL? {
        if let cached = cachedURL(forBundleID: bundleID) {
            return cached
        }
        guard let png = source.iconPNG(forBundleID: bundleID) else {
            return nil
        }

        let url = fileURL(forBundleID: bundleID)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Private

    private let source: any AppIconSource

    /// Where `bundleID`'s PNG belongs.
    ///
    /// The identifier comes from Apple's store, which means it is not ours to trust: a
    /// bundle id containing `/` or `..` would otherwise write outside the cache. Anything
    /// that is not a letter, digit, dot, dash or underscore becomes an underscore, which
    /// can collide between two hostile identifiers and cannot escape the directory —
    /// the right trade for a cache whose worst failure is the wrong glyph.
    private func fileURL(forBundleID bundleID: String) -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        let safe = String(bundleID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return directory.appendingPathComponent("\(safe.isEmpty ? "unknown" : safe).png")
    }
}
