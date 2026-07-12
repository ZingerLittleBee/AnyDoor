// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AnyDoor",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/riko2chen/AskForPermission.git",
            revision: "91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e"
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.2"
        ),
        // WebP encoder (BSD-3-Clause). ImageIO decodes WebP but cannot encode
        // it, so Target Size's same-format WebP path needs the bundled codec.
        .package(
            url: "https://github.com/SDWebImage/libwebp-Xcode.git",
            from: "1.5.0"
        ),
    ],
    targets: [
        .plugin(
            name: "XCStringsCompilerPlugin",
            capability: .buildTool(),
            path: "Plugins/XCStringsCompiler"
        ),
        .executableTarget(
            name: "AnyDoor",
            dependencies: [
                .product(name: "AskForPermission", package: "AskForPermission"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "libwebp", package: "libwebp-Xcode"),
                "HostsHelperShared",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            plugins: [
                .plugin(name: "XCStringsCompilerPlugin")
            ]
        ),
        .target(
            name: "HostsHelperShared",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "XPCAuditToken"
        ),
        .executableTarget(
            name: "AnyDoorHostsHelper",
            dependencies: ["HostsHelperShared", "XPCAuditToken"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "AnyDoorTests",
            dependencies: ["AnyDoor"],
            resources: [.process("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
