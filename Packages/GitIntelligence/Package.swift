// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GitIntelligence",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GitIntelligence", targets: ["GitIntelligence"])
    ],
    targets: [
        .target(
            name: "GitIntelligence",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
