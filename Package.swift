// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AnyDoor",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "AnyDoor",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "AnyDoorTests",
            dependencies: ["AnyDoor"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
