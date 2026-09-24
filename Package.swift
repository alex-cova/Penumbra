// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Swift 6 language mode is enabled on library, test, harness, and example targets.
// Do not set `defaultIsolation: MainActor` (SE-0476): EIP actors, background parse,
// and off-main search must stay nonisolated by default.

import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "Penumbra",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Penumbra", targets: ["Penumbra"]),
        .library(name: "EditorIntelligence", targets: ["EditorIntelligence"]),
        .library(name: "EditorIntelligenceLSP", targets: ["EditorIntelligenceLSP"]),
        .library(name: "PenumbraGraphQLLanguage", targets: ["PenumbraGraphQLLanguage"]),
        .library(name: "PenumbraMarkdownLanguage", targets: ["PenumbraMarkdownLanguage"]),
        .library(name: "PenumbraLanguages", targets: ["PenumbraLanguages"]),
        .library(name: "JavaIntelligence", targets: ["JavaIntelligence"]),
        .library(name: "HTTPClient", targets: ["HTTPClient"]),
        .library(name: "GitIntelligence", targets: ["GitIntelligence"])
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/LanguageClient", from: "0.8.0"),
        .package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", from: "0.14.0"),
        .package(url: "https://github.com/ChimeHQ/TextFormation", from: "0.9.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
        .package(url: "https://github.com/alex-cova/sunflower", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "TreeSitter",
            path: "Packages/TreeSitter/lib",
            exclude: [
                "src/unicode/ICU_SHA",
                "src/unicode/README.md",
                "src/unicode/LICENSE",
                "src/wasm/stdlib-symbols.txt"
            ],
            sources: ["src/lib.c"],
            cSettings: [
                .headerSearchPath("src"),
                .define("_POSIX_C_SOURCE", to: "200112L"),
                .define("_DEFAULT_SOURCE"),
                .define("_BSD_SOURCE"),
                .define("_DARWIN_C_SOURCE")
            ]
        ),
        .target(
            name: "PenumbraElkSwift",
            path: "Vendor/ElkSwift/Sources/ElkSwift",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "PenumbraBeautifulMermaid",
            dependencies: ["PenumbraElkSwift"],
            path: "Vendor/BeautifulMermaid/Sources/BeautifulMermaidSwift",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "EditorIntelligence", dependencies: [], swiftSettings: swift6),
        .target(
            name: "EditorIntelligenceLSP",
            dependencies: [
                "EditorIntelligence",
                .product(name: "LanguageClient", package: "LanguageClient"),
                .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol")
            ],
            swiftSettings: swift6
        ),
        .target(name: "Penumbra", dependencies: [
            "EditorIntelligence",
            "PenumbraBeautifulMermaid",
            "TreeSitter",
            .product(name: "TextFormation", package: "TextFormation")
        ], exclude: [
            "Documentation.docc"
        ], resources: [
            .copy("PrivacyInfo.xcprivacy"),
            .process("TextView/Appearance/Theme.xcassets")
        ], swiftSettings: swift6),
        // Native Java indexing/completion engine: no dependency on Penumbra, only on
        // EditorIntelligence and the vendored tree-sitter-java grammar. See
        // Sources/JavaIntelligence/README.md for the architecture.
        .target(
            name: "JavaIntelligence",
            dependencies: [
                "EditorIntelligence",
                "TreeSitter",
                "TreeSitterJava",
                .product(name: "FernflowerKit", package: "sunflower")
            ],
            swiftSettings: swift6
        ),
        .executableTarget(name: "SmokeTest", dependencies: ["Penumbra", "PenumbraMarkdownLanguage"], swiftSettings: swift6),
        .executableTarget(
            name: "PerfHarness",
            dependencies: ["Penumbra", "PenumbraMarkdownLanguage", "PenumbraLanguages"],
            path: "Tools/PerfHarness/Sources",
            swiftSettings: swift6
        ),
        .executableTarget(
            name: "Umbra",
            dependencies: [
                "Penumbra",
                "PenumbraLanguages",
                "PenumbraMarkdownLanguage",
                "JavaIntelligence",
                "HTTPClient",
                "GitIntelligence",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Example/Umbra",
            exclude: [
                "Tools/JavaDebugAdapter/build.sh",
                "Tools/JavaDebugAdapter/build/classes",
                "Tools/JavaDebugAdapter/build/test-classes",
                "Tools/JavaDebugAdapter/build/test-sources.txt",
                "Tools/JavaDebugAdapter/build/sources.txt",
                "Tools/JavaDebugAdapter/src"
            ],
            resources: [
                .copy("Tools/JavaDebugAdapter/build/java-debug-adapter.jar")
            ],
            swiftSettings: swift6
        ),
        .target(name: "TestTreeSitterLanguages"),
        .target(name: "TreeSitterGraphQL", cSettings: [
            .headerSearchPath("src")
        ]),
        .target(
            name: "PenumbraGraphQLLanguage",
            dependencies: [
                "Penumbra",
                "TreeSitterGraphQL"
            ],
            resources: [
                .copy("highlights.scm")
            ],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterMarkdown", exclude: ["LICENSE", "VERSION"], cSettings: [
            .headerSearchPath("src")
        ]),
        .target(name: "TreeSitterMarkdownInline", exclude: ["LICENSE", "VERSION"], cSettings: [
            .headerSearchPath("src")
        ]),
        .target(
            name: "TreeSitterCSS",
            cSettings: [
                .headerSearchPath("src")
            ]
        ),
        .target(
            name: "TreeSitterTypeScript",
            cSettings: [
                .headerSearchPath("src")
            ]
        ),

        // Per-language grammar packs migrated from Hextech's Vendor/PenumbraLanguages.
        // Each language is a trio: a C grammar target, a `*Queries` resource target,
        // and a `*Penumbra` target that adds the `TreeSitterLanguage` factory.
        .target(name: "TreeSitterTOML", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterTOMLQueries", resources: [.copy("highlights.scm")]),
        .target(
            name: "TreeSitterTOMLPenumbra",
            dependencies: ["Penumbra", "TreeSitterTOML", "TreeSitterTOMLQueries"],
            swiftSettings: swift6
        ),
        .target(
            name: "TreeSitterSQL",
            cSettings: [.headerSearchPath("src")],
            cxxSettings: [.headerSearchPath("src")]
        ),
        .target(name: "TreeSitterSQLQueries", resources: [.copy("highlights.scm")]),
        .target(
            name: "TreeSitterSQLPenumbra",
            dependencies: ["Penumbra", "TreeSitterSQL", "TreeSitterSQLQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterSwift", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterSwiftQueries",
            resources: [.copy("highlights.scm"), .copy("highlights-swiftui.scm"), .copy("locals.scm")]
        ),
        .target(
            name: "TreeSitterSwiftPenumbra",
            dependencies: ["Penumbra", "TreeSitterSwift", "TreeSitterSwiftQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterJava", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterJavaQueries",
            resources: [.copy("highlights.scm"), .copy("tags.scm")]
        ),
        .target(
            name: "TreeSitterJavaPenumbra",
            dependencies: ["Penumbra", "TreeSitterJava", "TreeSitterJavaQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterKotlin", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterKotlinQueries",
            resources: [.copy("highlights.scm"), .copy("tags.scm")]
        ),
        .target(
            name: "TreeSitterKotlinPenumbra",
            dependencies: ["Penumbra", "TreeSitterKotlin", "TreeSitterKotlinQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterGo", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterGoQueries",
            resources: [.copy("highlights.scm"), .copy("tags.scm")]
        ),
        .target(
            name: "TreeSitterGoPenumbra",
            dependencies: ["Penumbra", "TreeSitterGo", "TreeSitterGoQueries"],
            swiftSettings: swift6
        ),
        .target(
            name: "TreeSitterBash",
            cSettings: [.headerSearchPath("src")],
            cxxSettings: [.headerSearchPath("src")]
        ),
        .target(name: "TreeSitterBashQueries", resources: [.copy("highlights.scm")]),
        .target(
            name: "TreeSitterBashPenumbra",
            dependencies: ["Penumbra", "TreeSitterBash", "TreeSitterBashQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterHTTP", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterHTTPQueries", resources: [.copy("highlights.scm"), .copy("injections.scm")]),
        .target(
            name: "TreeSitterHTTPPenumbra",
            dependencies: ["Penumbra", "TreeSitterHTTP", "TreeSitterHTTPQueries"],
            swiftSettings: swift6
        ),
        .target(name: "GitIntelligence", swiftSettings: swift6),
        .target(
            name: "HTTPClient",
            dependencies: ["TreeSitter", "TreeSitterHTTP"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterMermaid", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterMermaidQueries", resources: [.copy("highlights.scm")]),
        .target(
            name: "TreeSitterMermaidPenumbra",
            dependencies: ["Penumbra", "TreeSitterMermaid", "TreeSitterMermaidQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterRust", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterRustQueries",
            resources: [.copy("highlights.scm")]
        ),
        .target(
            name: "TreeSitterRustPenumbra",
            dependencies: ["Penumbra", "TreeSitterRust", "TreeSitterRustQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterDiff", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterDiffQueries",
            resources: [.copy("highlights.scm")]
        ),
        .target(
            name: "TreeSitterDiffPenumbra",
            dependencies: ["Penumbra", "TreeSitterDiff", "TreeSitterDiffQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterC", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterCQueries",
            resources: [.copy("highlights.scm")]
        ),
        .target(
            name: "TreeSitterCPenumbra",
            dependencies: ["Penumbra", "TreeSitterC", "TreeSitterCQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterCpp", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterCppQueries",
            resources: [.copy("highlights.scm"), .copy("injections.scm")]
        ),
        .target(
            name: "TreeSitterCppPenumbra",
            dependencies: ["Penumbra", "TreeSitterCpp", "TreeSitterCppQueries", "TreeSitterCQueries"],
            swiftSettings: swift6
        ),
        .target(
            name: "PenumbraLanguages",
            dependencies: [
                "Penumbra",
                "TestTreeSitterLanguages",
                "TreeSitterCSS",
                "TreeSitterTypeScript",
                "PenumbraGraphQLLanguage",
                "PenumbraMarkdownLanguage",
                "TreeSitterTOMLPenumbra",
                "TreeSitterSQLPenumbra",
                "TreeSitterSwiftPenumbra",
                "TreeSitterJavaPenumbra",
                "TreeSitterKotlinPenumbra",
                "TreeSitterGoPenumbra",
                "TreeSitterBashPenumbra",
                "TreeSitterHTTPPenumbra",
                "TreeSitterMermaidPenumbra",
                "TreeSitterRustPenumbra",
                "TreeSitterCPenumbra",
                "TreeSitterCppPenumbra",
                "TreeSitterDiffPenumbra"
            ],
            resources: [
                .copy("Queries")
            ],
            swiftSettings: swift6
        ),
        .target(
            name: "PenumbraMarkdownLanguage",
            dependencies: [
                "Penumbra",
                "TreeSitterMarkdown",
                "TreeSitterMarkdownInline"
            ],
            resources: [
                .copy("Queries")
            ],
            swiftSettings: swift6
        ),
        .testTarget(name: "PenumbraTests", dependencies: [
            "Penumbra",
            "EditorIntelligence",
            "EditorIntelligenceLSP",
            "TestTreeSitterLanguages",
            "PenumbraGraphQLLanguage",
            "PenumbraMarkdownLanguage",
            "PenumbraLanguages",
            "PenumbraBeautifulMermaid",
            "JavaIntelligence",
            "HTTPClient",
            "GitIntelligence",
            .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol")
        ], resources: [.copy("Fixtures/Java"), .copy("Fixtures/Gradle")], swiftSettings: swift6)
    ]
)
