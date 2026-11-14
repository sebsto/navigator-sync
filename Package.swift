// swift-tools-version: 6.2
import PackageDescription

// Shared Swift settings applied to every target: Swift 6 language mode,
// MemberImportVisibility, and MainActor default isolation. Actors are used only
// for genuine background/shared-mutable work (the per-matter sync and the
// scheduler); everything else is MainActor by default.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("MemberImportVisibility"),
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "navigator-sync",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git",
            .upToNextMinor(from: "0.4.0")
        ),
    ],
    targets: [
        // Shared, testable logic: models, CLI clients, engine, parsing.
        .target(
            name: "NavigatorSyncCore",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            path: "Sources/NavigatorSyncCore",
            swiftSettings: swiftSettings
        ),

        // macOS menu-bar app (thin UI over the core).
        .executableTarget(
            name: "NavigatorSync",
            dependencies: ["NavigatorSyncCore"],
            path: "Sources/NavigatorSync",
            swiftSettings: swiftSettings
        ),

        // Unit tests (Swift Testing).
        .testTarget(
            name: "NavigatorSyncCoreTests",
            dependencies: ["NavigatorSyncCore"],
            path: "Tests/NavigatorSyncCoreTests",
            swiftSettings: swiftSettings
        ),

        // App-logic tests (onboarding coordinator, settings, readiness).
        .testTarget(
            name: "NavigatorSyncAppTests",
            dependencies: ["NavigatorSync"],
            path: "Tests/NavigatorSyncAppTests",
            swiftSettings: swiftSettings
        ),
    ]
)
