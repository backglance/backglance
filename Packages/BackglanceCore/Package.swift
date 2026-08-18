// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BackglanceCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackglanceCore", targets: ["BackglanceCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "BackglanceCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"), // warning-clean under Swift 6 toolchain
            ]
        ),
        .testTarget(
            name: "BackglanceCoreTests",
            dependencies: ["BackglanceCore"],
            path: "Tests/BackglanceCoreTests"
        ),
    ]
)
