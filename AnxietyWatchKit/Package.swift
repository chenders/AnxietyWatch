// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AnxietyWatchKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14)
    ],
    products: [
        // Products define what targets are visible to other packages and applications.
        .library(
            name: "AnxietyWatchKit",
            targets: ["AnxietyWatchKit"]
        )
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "6.29.3"))
    ],
    targets: [
        // Targets are the basic building blocks of a package.
        .target(
            name: "AnxietyWatchKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/AnxietyWatchKit"
        ),
        .testTarget(
            name: "AnxietyWatchKitTests",
            dependencies: ["AnxietyWatchKit"],
            path: "Tests/AnxietyWatchKitTests"
        )
    ]
)