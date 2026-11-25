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
        // Values, result storage, capabilities, redaction: no drivers, no I/O beyond a temp file.
        .target(
            name: "DatabaseCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DatabaseCoreTests",
            dependencies: ["DatabaseCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The SQL language model: lexer, statement splitter, scope analysis, completion and
        // diagnostics. Pure, no I/O, no drivers: it reads a catalog snapshot it is handed.
        .target(
            name: "SQLIntelligence",
            dependencies: ["DatabaseCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SQLIntelligenceTests",
            dependencies: ["SQLIntelligence"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DatabaseKit",
            dependencies: [
                "DatabaseCore",
                "SQLIntelligence",
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
