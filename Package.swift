// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Ports",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Ports",
            path: "Sources",
            exclude: ["Info.plist"],
            resources: [
                .process("Assets.xcassets")
            ]
        )
    ]
)
