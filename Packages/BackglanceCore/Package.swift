// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackglanceCore",
    // `defaultLocalization` does not give this package a catalog of its own, and is not
    // meant to: every `String(localized:)` here resolves against `Bundle.main`, which is
    // Backglance.app, so the keys belong in the one catalog at
    // Backglance/Resources/Localizable.xcstrings (INTERNATIONALIZATION.md). What it does is
    // make `xcodebuild -exportLocalizations` walk this target at all — without it the
    // strings are extracted nowhere, and Scripts/sync_string_catalog.sh cannot find them.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackglanceCore", targets: ["BackglanceCore"]),
    ],
    dependencies: [
        .package(path: "../../Tests/BackglanceTestSupport"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "BackglanceCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5), // tools-version 6.0 would otherwise default to language mode 6
                .enableUpcomingFeature("StrictConcurrency"), // warning-clean under Swift 6 toolchain
            ]
        ),
        .testTarget(
            name: "BackglanceCoreTests",
            dependencies: ["BackglanceCore", "BackglanceTestSupport"],
            path: "Tests/BackglanceCoreTests",
            // No `exclude:` and no fixture resources — see the matching note in
            // Packages/BackglanceCapture/Package.swift for why the `SharedFixtures`
            // symlink that used to be excluded here is gone (BACKGLANCE-255).
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
