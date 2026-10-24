// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentKitApple",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "AgentKitApple", targets: ["AgentKitApple"])
    ],
    dependencies: [
        .package(path: "../AgentKit")
    ],
    targets: [
        // Apple's foundation models (on device, and Private Cloud Compute on macOS 27) as an `LLMClient`.
        .target(
            name: "AgentKitApple",
            dependencies: [.product(name: "AgentKit", package: "AgentKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AgentKitAppleTests",
            dependencies: ["AgentKitApple", .product(name: "AgentKit", package: "AgentKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
