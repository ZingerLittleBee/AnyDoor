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
        // Shared plugin interface (ADR-0005/0006/0007): the closed command
        // catalog, the Native Plugin protocol surface, and the palette row
        // descriptors. Lean by design — it must never depend on Core
        // palette/UI types such as PanelEntry.
        .target(
            name: "PluginInterface",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Pure image-codec utilities shared by Core and the Image Conversion
        // plugin: the format whitelist and the ImageIO encode path plus the
        // shared lossy-quality setting. Core's screenshot Save As transcodes
        // through this target so it never depends on the plugin module. WebP
        // encoding (bundled libwebp) is plugin-only and stays out.
        .target(
            name: "ImageCodec",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Native Plugin pilot (ADR-0005): the Image Conversion feature as its
        // own module. It touches the host only through PluginInterface's host
        // services; the app target depends on it to build the compile-time
        // plugin registry list (plus the one registered-debt call site the
        // PRD carves out: the clipboard-history context menu).
        .target(
            name: "ImageConversionPlugin",
            dependencies: [
                .product(name: "libwebp", package: "libwebp-Xcode"),
                "ImageCodec",
                "PluginInterface",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Native Plugin pilot (ADR-0005): the Hosts feature as its own module
        // — profiles, /etc/hosts parse+compose, the editor window, popover,
        // and palette contributions. The privileged helper daemon (XPC
        // plumbing, SMAppService lifecycle) stays Core infrastructure; the
        // plugin reaches it through PluginInterface's host services.
        .target(
            name: "HostsPlugin",
            dependencies: [
                "PluginInterface",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "AnyDoor",
            dependencies: [
                .product(name: "AskForPermission", package: "AskForPermission"),
                .product(name: "Sparkle", package: "Sparkle"),
                "HostsHelperShared",
                "ImageCodec",
                "PluginInterface",
                "ImageConversionPlugin",
                "HostsPlugin",
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
            dependencies: ["AnyDoor", "ImageCodec", "PluginInterface", "ImageConversionPlugin", "HostsPlugin"],
            resources: [.process("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
