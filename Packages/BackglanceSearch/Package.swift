// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackglanceSearch",
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
