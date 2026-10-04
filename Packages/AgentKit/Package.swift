// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"])
    ],
    targets: [
        .target(
            name: "AgentKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
