// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "JarvisIOS",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "JarvisProtocol", targets: ["JarvisProtocol"]),
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
    ],
    targets: [
        .target(name: "JarvisProtocol"),
        .target(
            name: "JarvisCore",
            dependencies: ["JarvisProtocol"]
        ),
        .testTarget(
            name: "JarvisProtocolTests",
            dependencies: ["JarvisProtocol"]
        ),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore", "JarvisProtocol"]
        ),
    ]
)
