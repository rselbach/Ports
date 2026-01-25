// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Ports",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Ports",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            exclude: ["Info.plist", "Entitlements.plist"],
            resources: [
                .process("Assets.xcassets")
            ]
        )
    ]
)
