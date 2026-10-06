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
    dependencies: [
        .package(path: "../SubprocessKit")
    ],
    targets: [
        .target(
            name: "GitIntelligence",
            dependencies: [.product(name: "SubprocessKit", package: "SubprocessKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
