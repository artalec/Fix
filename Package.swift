// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DJPlayer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DJPlayer", targets: ["DJPlayer"])
    ],
    targets: [
        .executableTarget(
            name: "DJPlayer",
            path: "Sources"
        )
    ]
)
