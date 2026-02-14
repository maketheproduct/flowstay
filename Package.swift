// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Flowstay",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "Flowstay",
            targets: ["Flowstay"]
        ),
    ],
    dependencies: [
        // KeyboardShortcuts for modern global hotkey management
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        // FluidAudio for modern ASR with Parakeet TDT
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.7.9"),
        // Sparkle for auto-updates
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Main app executable
        .executableTarget(
            name: "Flowstay",
            dependencies: [
                "FlowstayCore",
                "FlowstayUI",
                "FlowstayPermissions",
                "KeyboardShortcuts",
            ],
            path: "Sources/Flowstay",
            exclude: ["Info.plist"],
            resources: [
                .copy("AppIcon.icns"),
                .copy("Resources/Flowstay.icon"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),

        // Core module - Speech recognition, models, utilities
        .target(
            name: "FlowstayCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "KeyboardShortcuts",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/FlowstayCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),

        // UI module - All user interface components
        .target(
            name: "FlowstayUI",
            dependencies: [
                "FlowstayCore",
                "FlowstayPermissions",
                "KeyboardShortcuts",
            ],
            path: "Sources/FlowstayUI",
            resources: [
                .process("Assets"),
                .process("Fonts"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),

        // Permissions module - Onboarding and permission management
        .target(
            name: "FlowstayPermissions",
            dependencies: [
                "FlowstayCore",
            ],
            path: "Sources/FlowstayPermissions",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),

        .testTarget(
            name: "FlowstayCoreTests",
            dependencies: ["FlowstayCore"],
            path: "Tests/FlowstayCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
