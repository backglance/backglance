import Foundation

// MARK: - Fixtures

/// Where the checked-in fixtures are, found from this file's own source path.
///
/// The obvious alternative — `Bundle.module` over the `resources:` a test target
/// declares — only exists when the test bundle is built by SwiftPM. The same sources are
/// also compiled by the `Backglance.xcodeproj` test targets, which get no generated
/// accessor, so `Bundle.module` there resolves to some *other* module's internal one and
/// the bundle does not compile at all. `#filePath` is the one answer that is the same
/// under `swift test`, under `xcodebuild test`, and in Xcode's test navigator.
///
/// The trade is that the fixtures are read from the working copy rather than from a copy
/// inside the test bundle. That is what we want anyway: they are large, they are
/// read-only inputs, and a test that needs to write opens a copy in a temporary
/// directory. It does mean a test bundle cannot be run detached from its checkout, which
/// nothing does.
///
/// See docs/testing/TESTING.md#test-bundles-and-directories.
public enum Fixtures {
    /// `Tests/Fixtures/`.
    public static let root: URL = {
        // …/Tests/BackglanceTestSupport/Sources/BackglanceTestSupport/FixtureLocator.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("Fixtures", isDirectory: true)
    }()

    /// `Tests/Fixtures/SystemStore/` — one directory per supported macOS, all synthetic.
    public static var systemStore: URL {
        root.appendingPathComponent("SystemStore", isDirectory: true)
    }

    /// `Tests/Fixtures/Archive/` — frozen archives (`v*.sqlite`) with synthetic rows.
    public static var archive: URL {
        root.appendingPathComponent("Archive", isDirectory: true)
    }

    /// Whether the fixture directory is actually there.
    ///
    /// A harness that silently tests nothing is worse than no harness, so the callers
    /// assert on this rather than treating an empty directory listing as "no fixtures to
    /// check".
    public static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
