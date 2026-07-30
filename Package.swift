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
        // TestClock for time-dependent tests (MIT). Test-target only: production
        // code takes the stdlib `Clock` protocol and defaults to
        // `ContinuousClock`, so nothing from this package reaches the app
        // binary. A test that drives a fake clock cannot race a real one, which
        // is the difference between an unlikely flake and an impossible one.
        .package(
            url: "https://github.com/pointfreeco/swift-clocks",
            from: "1.1.0"
        ),
        .package(
            url: "https://github.com/sqlcipher/GRDB.swift.git",
            exact: "7.11.1"
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
        // Shared implementation support used on both sides of the plugin
        // boundary: the plain-text editor, hover/glass shims, thumbnail cache,
        // capture-filename helpers, and main-thread isolation. Deliberately a
        // sibling of PluginInterface, which stays a pure contract — these are
        // conveniences both Core and plugin modules happen to need, not part
        // of the plugin interface.
        .target(
            name: "PluginSupport",
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
        .target(
            name: "ClipboardHistory",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Native Plugin pilot (ADR-0005): the Image Conversion feature as its
        // own module. It touches the host only through PluginInterface's host
        // services; the app target depends on it for NativePluginCatalog plus
        // the one registered-debt concrete call site: the clipboard-history
        // context menu resolves the installed plugin instance via the registry.
        .target(
            name: "ImageConversionPlugin",
            dependencies: [
                .product(name: "libwebp", package: "libwebp-Xcode"),
                "ImageCodec",
                "PluginInterface",
                "PluginSupport",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // C shim exposing JavaScriptCore's private execution-time-limit API
        // (ADR-0008 watchdog). The symbol is exported by the framework dylib
        // but missing from the public SDK headers, so it is redeclared here —
        // the same sanctioned technique as the XPCAuditToken ObjC shim.
        .target(
            name: "JavaScriptCoreWatchdog",
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
            ]
        ),
        // Script Plugin runtime (ADR-0008/0009): the headless heart of the
        // Script Plugin milestone. One inspectable JSContext per plugin on its
        // own serial queue, promise-bridged capability calls gated by the
        // manifest, and a hard watchdog. Depends only on PluginInterface (for
        // the row descriptor it emits) plus the watchdog shim; it never touches
        // Core, so the registry (ticket 021) wires it in through the capability
        // host seam.
        .target(
            name: "ScriptPluginRuntime",
            dependencies: [
                "PluginInterface",
                "JavaScriptCoreWatchdog",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
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
                "PluginSupport",
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
                "PluginSupport",
                "ImageConversionPlugin",
                "HostsPlugin",
                "ScriptPluginRuntime",
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
            dependencies: [
                .product(name: "Clocks", package: "swift-clocks"),
                "AnyDoor", "ImageCodec", "PluginInterface", "PluginSupport",
                "ImageConversionPlugin", "HostsPlugin", "ScriptPluginRuntime",
            ],
            resources: [.process("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ClipboardHistoryTests",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "ClipboardHistory",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
