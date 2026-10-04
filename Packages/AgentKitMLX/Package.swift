// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentKitMLX",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LocalModelStore", targets: ["LocalModelStore"]),
        .library(name: "AgentKitMLX", targets: ["AgentKitMLX"]),
    ],
    dependencies: [
        .package(path: "../AgentKit"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        // Hugging Face search, downloads and the installed-model catalog. Foundation and Security
        // only: no MLX, so it builds fast and runs on any Mac.
        .target(
            name: "LocalModelStore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The MLX side: loading, the `LLMClient`, tool-call parsing. Apple silicon only at run time.
        .target(
            name: "AgentKitMLX",
            dependencies: [
                "LocalModelStore",
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LocalModelStoreTests",
            dependencies: ["LocalModelStore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AgentKitMLXTests",
            dependencies: ["AgentKitMLX", .product(name: "AgentKit", package: "AgentKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
