// swift-tools-version: 5.10
import PackageDescription

/// Test-only helpers shared by all four test bundles.
///
/// It lives under `Tests/` rather than `Packages/` because it ships in no build of the
/// app: only the test targets of the four packages depend on it, so the dependency
/// direction described in DEVELOPMENT_GUIDE.md is unaffected.
let package = Package(
    name: "BackglanceTestSupport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackglanceTestSupport", targets: ["BackglanceTestSupport"]),
    ],
    targets: [
        .target(
            name: "BackglanceTestSupport",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
    ]
)
