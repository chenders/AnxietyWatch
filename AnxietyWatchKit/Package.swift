// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

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
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "6.29.3")),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "510.0.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package.
        .macro(
            name: "AnxietyWatchKitMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ],
            path: "Sources/AnxietyWatchKitMacros"
        ),
        .target(
            name: "AnxietyWatchKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "AnxietyWatchKitMacros"
            ],
            path: "Sources/AnxietyWatchKit"
        ),
        .testTarget(
            name: "AnxietyWatchKitTests",
            dependencies: ["AnxietyWatchKit"],
            path: "Tests/AnxietyWatchKitTests"
        ),
        .testTarget(
            name: "AnxietyWatchKitMacrosTests",
            dependencies: [
                "AnxietyWatchKitMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ],
            path: "Tests/AnxietyWatchKitMacrosTests"
        )
    ]
)
