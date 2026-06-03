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
        .package(
            url: "https://github.com/reitermarkus/DDC.swift",
            branch: "master"
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
                .product(name: "DDC", package: "DDC.swift"),
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
        .executableTarget(
            name: "AnyDoorHostsHelper",
            dependencies: ["HostsHelperShared"],
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
