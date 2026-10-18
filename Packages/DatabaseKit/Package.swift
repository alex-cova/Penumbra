// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DatabaseKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DatabaseKit", targets: ["DatabaseKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-kit.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/postgres-kit.git", from: "2.0.0"),
        .package(url: "https://github.com/orlandos-nl/MongoKitten.git", from: "7.16.0")
    ],
    targets: [
        .target(
            name: "DatabaseKit",
            dependencies: [
                .product(name: "MySQLKit", package: "mysql-kit"),
                .product(name: "PostgresKit", package: "postgres-kit"),
                .product(name: "MongoKitten", package: "MongoKitten")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DatabaseKitTests",
            dependencies: ["DatabaseKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
