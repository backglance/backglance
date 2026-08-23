// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackglanceSearch",
    // `defaultLocalization` does not give this package a catalog of its own, and is not
    // meant to: every `String(localized:)` here resolves against `Bundle.main`, which is
    // Backglance.app, so the keys belong in the one catalog at
    // Backglance/Resources/Localizable.xcstrings (INTERNATIONALIZATION.md). What it does is
    // make `xcodebuild -exportLocalizations` walk this target at all — without it the
    // strings are extracted nowhere, and Scripts/sync_string_catalog.sh cannot find them.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackglanceSearch", targets: ["BackglanceSearch"]),
    ],
    dependencies: [
        .package(path: "../../Tests/BackglanceTestSupport"),
        .package(path: "../BackglanceCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "BackglanceSearch",
            dependencies: [
                "BackglanceCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .testTarget(
            name: "BackglanceSearchTests",
            dependencies: ["BackglanceSearch", "BackglanceTestSupport"],
            path: "Tests/BackglanceSearchTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
