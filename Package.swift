// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Swift 6 language mode is enabled on library, test, harness, and example targets.
// Do not set `defaultIsolation: MainActor` (SE-0476): EIP actors, background parse,
// and off-main search must stay nonisolated by default.

import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "Runestone",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "Runestone", targets: ["Runestone"]),
        .library(name: "EditorIntelligence", targets: ["EditorIntelligence"]),
        .library(name: "EditorIntelligenceLSP", targets: ["EditorIntelligenceLSP"]),
        .library(name: "RunestoneGraphQLLanguage", targets: ["RunestoneGraphQLLanguage"]),
        .library(name: "RunestoneMarkdownLanguage", targets: ["RunestoneMarkdownLanguage"]),
        .library(name: "RunestoneLanguages", targets: ["RunestoneLanguages"])
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/LanguageClient", from: "0.8.0"),
        .package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", from: "0.14.0"),
        .package(url: "https://github.com/ChimeHQ/TextFormation", from: "0.9.0")
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
            name: "RunestoneElkSwift",
            path: "Vendor/ElkSwift/Sources/ElkSwift",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "RunestoneBeautifulMermaid",
            dependencies: ["RunestoneElkSwift"],
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
        .target(name: "Runestone", dependencies: [
            "EditorIntelligence",
            "RunestoneBeautifulMermaid",
            "TreeSitter",
            .product(name: "TextFormation", package: "TextFormation")
        ], exclude: [
            "Documentation.docc"
        ], resources: [
            .copy("PrivacyInfo.xcprivacy"),
            .process("TextView/Appearance/Theme.xcassets")
        ], swiftSettings: swift6),
        .executableTarget(name: "SmokeTest", dependencies: ["Runestone", "RunestoneMarkdownLanguage"], swiftSettings: swift6),
        .executableTarget(
            name: "PerfHarness",
            dependencies: ["Runestone", "RunestoneMarkdownLanguage", "RunestoneLanguages"],
            path: "Tools/PerfHarness/Sources",
            swiftSettings: swift6
        ),
        .executableTarget(
            name: "Umbra",
            dependencies: ["Runestone", "RunestoneLanguages", "RunestoneMarkdownLanguage"],
            path: "Example/Umbra",
            swiftSettings: swift6
        ),
        .target(name: "TestTreeSitterLanguages"),
        .target(name: "TreeSitterGraphQL", cSettings: [
            .headerSearchPath("src")
        ]),
        .target(
            name: "RunestoneGraphQLLanguage",
            dependencies: [
                "Runestone",
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

        // Per-language grammar packs migrated from Hextech's Vendor/RunestoneLanguages.
        // Each language is a trio: a C grammar target, a `*Queries` resource target,
        // and a `*Runestone` target that adds the `TreeSitterLanguage` factory.
        .target(name: "TreeSitterTOML", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterTOMLQueries", resources: [.copy("highlights.scm")]),
        .target(
            name: "TreeSitterTOMLRunestone",
            dependencies: ["Runestone", "TreeSitterTOML", "TreeSitterTOMLQueries"],
            swiftSettings: swift6
        ),
        .target(
            name: "TreeSitterSQL",
            cSettings: [.headerSearchPath("src")],
            cxxSettings: [.headerSearchPath("src")]
        ),
        .target(name: "TreeSitterSQLQueries", resources: [.copy("highlights.scm")]),
        .target(
            name: "TreeSitterSQLRunestone",
            dependencies: ["Runestone", "TreeSitterSQL", "TreeSitterSQLQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterSwift", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterSwiftQueries",
            resources: [.copy("highlights.scm"), .copy("highlights-swiftui.scm"), .copy("locals.scm")]
        ),
        .target(
            name: "TreeSitterSwiftRunestone",
            dependencies: ["Runestone", "TreeSitterSwift", "TreeSitterSwiftQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterJava", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterJavaQueries",
            resources: [.copy("highlights.scm"), .copy("tags.scm")]
        ),
        .target(
            name: "TreeSitterJavaRunestone",
            dependencies: ["Runestone", "TreeSitterJava", "TreeSitterJavaQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterKotlin", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterKotlinQueries",
            resources: [.copy("highlights.scm"), .copy("tags.scm")]
        ),
        .target(
            name: "TreeSitterKotlinRunestone",
            dependencies: ["Runestone", "TreeSitterKotlin", "TreeSitterKotlinQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterGo", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterGoQueries",
            resources: [.copy("highlights.scm"), .copy("tags.scm")]
        ),
        .target(
            name: "TreeSitterGoRunestone",
            dependencies: ["Runestone", "TreeSitterGo", "TreeSitterGoQueries"],
            swiftSettings: swift6
        ),
        .target(
            name: "TreeSitterBash",
            cSettings: [.headerSearchPath("src")],
            cxxSettings: [.headerSearchPath("src")]
        ),
        .target(name: "TreeSitterBashQueries", resources: [.copy("highlights.scm")]),
        .target(
            name: "TreeSitterBashRunestone",
            dependencies: ["Runestone", "TreeSitterBash", "TreeSitterBashQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterHTTP", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterHTTPQueries", resources: [.copy("highlights.scm")]),
        .target(
            name: "TreeSitterHTTPRunestone",
            dependencies: ["Runestone", "TreeSitterHTTP", "TreeSitterHTTPQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterMermaid", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterMermaidQueries", resources: [.copy("highlights.scm")]),
        .target(
            name: "TreeSitterMermaidRunestone",
            dependencies: ["Runestone", "TreeSitterMermaid", "TreeSitterMermaidQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterRust", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterRustQueries",
            resources: [.copy("highlights.scm")]
        ),
        .target(
            name: "TreeSitterRustRunestone",
            dependencies: ["Runestone", "TreeSitterRust", "TreeSitterRustQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterC", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterCQueries",
            resources: [.copy("highlights.scm")]
        ),
        .target(
            name: "TreeSitterCRunestone",
            dependencies: ["Runestone", "TreeSitterC", "TreeSitterCQueries"],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterCpp", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterCppQueries",
            resources: [.copy("highlights.scm"), .copy("injections.scm")]
        ),
        .target(
            name: "TreeSitterCppRunestone",
            dependencies: ["Runestone", "TreeSitterCpp", "TreeSitterCppQueries", "TreeSitterCQueries"],
            swiftSettings: swift6
        ),
        .target(
            name: "RunestoneLanguages",
            dependencies: [
                "Runestone",
                "TestTreeSitterLanguages",
                "TreeSitterCSS",
                "TreeSitterTypeScript",
                "RunestoneGraphQLLanguage",
                "RunestoneMarkdownLanguage",
                "TreeSitterTOMLRunestone",
                "TreeSitterSQLRunestone",
                "TreeSitterSwiftRunestone",
                "TreeSitterJavaRunestone",
                "TreeSitterKotlinRunestone",
                "TreeSitterGoRunestone",
                "TreeSitterBashRunestone",
                "TreeSitterHTTPRunestone",
                "TreeSitterMermaidRunestone",
                "TreeSitterRustRunestone",
                "TreeSitterCRunestone",
                "TreeSitterCppRunestone"
            ],
            resources: [
                .copy("Queries")
            ],
            swiftSettings: swift6
        ),
        .target(
            name: "RunestoneMarkdownLanguage",
            dependencies: [
                "Runestone",
                "TreeSitterMarkdown",
                "TreeSitterMarkdownInline"
            ],
            resources: [
                .copy("Queries")
            ],
            swiftSettings: swift6
        ),
        .testTarget(name: "RunestoneTests", dependencies: [
            "Runestone",
            "EditorIntelligence",
            "EditorIntelligenceLSP",
            "TestTreeSitterLanguages",
            "RunestoneGraphQLLanguage",
            "RunestoneMarkdownLanguage",
            "RunestoneLanguages",
            .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol")
        ], swiftSettings: swift6)
    ]
)
