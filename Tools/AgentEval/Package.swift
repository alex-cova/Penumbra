// swift-tools-version: 6.2
// The agent evaluator: scripted tasks, a real model, a verdict from the project's own tests.
// It links the on-device model stacks, so it is its own package instead of a target of the root
// library package. Run it from here: `swift run AgentEval`.

import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "AgentEval",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(name: "Penumbra", path: "../.."),
        .package(path: "../../Packages/AgentKit"),
        .package(path: "../../Packages/AgentKitMLX"),
        .package(path: "../../Packages/AgentKitApple")
    ],
    targets: [
        .target(
            name: "AgentEvalKit",
            dependencies: [
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "SubprocessKit", package: "Penumbra")
            ],
            path: "Sources/AgentEvalKit",
            swiftSettings: swift6
        ),
        .executableTarget(
            name: "AgentEval",
            dependencies: [
                "AgentEvalKit",
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "AgentKitMLX", package: "AgentKitMLX"),
                .product(name: "LocalModelStore", package: "AgentKitMLX"),
                .product(name: "AgentKitApple", package: "AgentKitApple"),
            ],
            path: "Sources/AgentEval",
            swiftSettings: swift6
        ),
        .testTarget(
            name: "AgentEvalTests",
            dependencies: ["AgentEvalKit", .product(name: "AgentKit", package: "AgentKit")],
            path: "Tests/AgentEvalTests",
            swiftSettings: swift6
        )
    ]
)
