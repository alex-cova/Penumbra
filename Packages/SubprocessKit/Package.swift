// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SubprocessKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SubprocessKit", targets: ["SubprocessKit"])
    ],
    targets: [
        .target(
            name: "SubprocessKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SubprocessKitTests",
            dependencies: ["SubprocessKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
