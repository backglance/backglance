// swift-tools-version: 6.0
import PackageDescription

/// SwiftUI views shared by the popover, the timeline window and (v1.x) the widgets.
///
/// No GRDB and no BackglanceCapture: views take models and closures, never a database
/// handle or a capture engine — see DEVELOPMENT_GUIDE.md, "Dependency direction".
let package = Package(
    name: "BackglanceUI",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackglanceUI", targets: ["BackglanceUI"]),
    ],
    dependencies: [
        .package(path: "../../Tests/BackglanceTestSupport"),
        .package(path: "../BackglanceCore"),
    ],
    targets: [
        .target(
            name: "BackglanceUI",
            dependencies: [
                "BackglanceCore",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "BackglanceUITests",
            dependencies: ["BackglanceUI", "BackglanceCore", "BackglanceTestSupport"],
            path: "Tests/BackglanceUITests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
