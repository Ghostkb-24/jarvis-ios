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
        .library(name: "JarvisVoice", targets: ["JarvisVoice"]),
    ],
    targets: [
        .target(name: "JarvisProtocol"),
        .target(
            name: "JarvisCore",
            dependencies: ["JarvisProtocol"]
        ),
        .target(
            name: "JarvisVoice",
            path: "JarvisIOS/Voice",
            exclude: ["SpeechPermissionView.swift"],
            sources: ["SpeechSession.swift"]
        ),
        .testTarget(
            name: "JarvisProtocolTests",
            dependencies: ["JarvisProtocol"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore", "JarvisProtocol", "JarvisVoice"]
        ),
    ]
)
