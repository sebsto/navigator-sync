// swift-tools-version: 6.2
import PackageDescription

// Base settings for every target: Swift 6 language mode + MemberImportVisibility.
let baseSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("MemberImportVisibility"),
]

// The app and its UI are MainActor by default (SwiftUI is main-actor anyway),
// so UI types need no annotation. The Core library deliberately does NOT use
// MainActor default isolation: it is pure data plus background sync actors, so
// its types stay non-isolated by default and are freely usable from the engine
// actors without `nonisolated` noise.
let uiSwiftSettings: [SwiftSetting] = baseSwiftSettings + [
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
            swiftSettings: baseSwiftSettings
        ),

        // macOS menu-bar app (thin UI over the core).
        .executableTarget(
            name: "NavigatorSync",
            dependencies: ["NavigatorSyncCore"],
            path: "Sources/NavigatorSync",
            swiftSettings: uiSwiftSettings
        ),

        // Unit tests (Swift Testing).
        .testTarget(
            name: "NavigatorSyncCoreTests",
            dependencies: ["NavigatorSyncCore"],
            path: "Tests/NavigatorSyncCoreTests",
            swiftSettings: baseSwiftSettings
        ),

        // App-logic tests (onboarding coordinator, settings, readiness).
        .testTarget(
            name: "NavigatorSyncAppTests",
            dependencies: ["NavigatorSync"],
            path: "Tests/NavigatorSyncAppTests",
            swiftSettings: uiSwiftSettings
        ),
    ]
)
