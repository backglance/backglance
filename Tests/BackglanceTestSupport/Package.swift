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
    dependencies: [
        // Test-only, and so is this package: the seeded archives the performance
        // suites measure against are built through `Archive` itself, so they go
        // through the same migrations and the same FTS triggers the app does.
        .package(path: "../../Packages/BackglanceCore"),
    ],
    targets: [
        .target(
            name: "BackglanceTestSupport",
            dependencies: ["BackglanceCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
    ]
)
