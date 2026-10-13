// swift-tools-version: 6.2
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
        .macOS(.v26)
    ],
    products: [
        .library(name: "Penumbra", targets: ["Penumbra"]),
        .library(name: "EditorIntelligence", targets: ["EditorIntelligence"]),
        .library(name: "EditorIntelligenceLSP", targets: ["EditorIntelligenceLSP"]),
        .library(name: "PenumbraGraphQLLanguage", targets: ["PenumbraGraphQLLanguage"]),
        .library(name: "PenumbraMarkdownLanguage", targets: ["PenumbraMarkdownLanguage"]),
        .library(name: "PenumbraLanguages", targets: ["PenumbraLanguages"]),
        .library(name: "LanguageSyntax", targets: ["LanguageSyntax"]),
        .library(name: "JavaIntelligence", targets: ["JavaIntelligence"]),
        .library(name: "SwiftIntelligence", targets: ["SwiftIntelligence"]),
        .library(name: "TypeScriptIntelligence", targets: ["TypeScriptIntelligence"]),
        .library(name: "HexKit", targets: ["HexKit"]),
        // Umbra's Xcode project links these through the root package. Referencing
        // `Packages/SubprocessKit` as well would declare the target twice in one package graph.
        .library(name: "SubprocessKit", targets: ["SubprocessKit"]),
        .library(name: "GitIntelligence", targets: ["GitIntelligence"])
    ],
    dependencies: [
        .package(path: "Packages/AgentKit"),
        .package(path: "Packages/AgentKitMLX"),
        .package(url: "https://github.com/ChimeHQ/LanguageClient", from: "0.8.0"),
        .package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", from: "0.14.0"),
        .package(url: "https://github.com/ChimeHQ/JSONRPC", from: "0.9.0"),
        .package(url: "https://github.com/ChimeHQ/TextFormation", from: "0.9.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
        .package(url: "https://github.com/alex-cova/sunflower", from: "1.0.0"),
        .package(url: "https://github.com/alex-cova/DiagramKit", from: "1.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/apple/xcode-project-format", from: "0.1.0")
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
        .target(name: "EditorIntelligence", dependencies: [], exclude: ["CLAUDE.md"], swiftSettings: swift6),
        // Vendored as targets (not separate SPM packages) so editor consumers like Hextech do not
        // resolve SubprocessKit in their package graph.
        .target(
            name: "SubprocessKit",
            path: "Packages/SubprocessKit/Sources/SubprocessKit",
            swiftSettings: swift6
        ),
        .target(
            name: "GitIntelligence",
            dependencies: ["SubprocessKit"],
            path: "Packages/GitIntelligence/Sources/GitIntelligence",
            swiftSettings: swift6
        ),
        .target(
            name: "EditorIntelligenceLSP",
            dependencies: [
                "EditorIntelligence",
                .product(name: "LanguageClient", package: "LanguageClient"),
                .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
                .product(name: "JSONRPC", package: "JSONRPC")
            ],
            swiftSettings: swift6
        ),
        .target(name: "Penumbra", dependencies: [
            "EditorIntelligence",
            "PenumbraBeautifulMermaid",
            "TreeSitter",
            .product(name: "TextFormation", package: "TextFormation")
        ], exclude: [
            "CLAUDE.md",
            "Documentation.docc",
            "Workbench/CLAUDE.md"
        ], resources: [
            .copy("PrivacyInfo.xcprivacy"),
            .process("TextView/Appearance/Theme.xcassets")
        ], swiftSettings: swift6),
        // Native Java indexing/completion engine: no dependency on Penumbra, only on
        // EditorIntelligence and the vendored tree-sitter-java grammar. See
        // Sources/JavaIntelligence/README.md for the architecture.
        .target(
            name: "LanguageSyntax",
            dependencies: [
                "EditorIntelligence",
                "TreeSitter"
            ],
            swiftSettings: swift6
        ),
        .target(
            name: "JavaIntelligence",
            dependencies: [
                "EditorIntelligence",
                "LanguageSyntax",
                "TreeSitter",
                "TreeSitterJava",
                .product(name: "FernflowerKit", package: "sunflower"),
                "SubprocessKit"
            ],
            exclude: ["CLAUDE.md"],
            swiftSettings: swift6
        ),
        // Syntactic Swift and TypeScript engines. They still parse through JavaIntelligence's
        // syntax types until LanguageSyntax exists (docs/LANGUAGE_PARITY_PLAN.md, phase 1).
        // Umbra-only wiring (support objects, SwiftPM, the palette) stays in the app target.
        .target(
            name: "SwiftIntelligence",
            dependencies: [
                "EditorIntelligence",
                "LanguageSyntax",
                "TreeSitterSwift"
            ],
            swiftSettings: swift6
        ),
        .target(
            name: "TypeScriptIntelligence",
            dependencies: [
                "EditorIntelligence",
                "LanguageSyntax",
                "TreeSitterTypeScript"
            ],
            swiftSettings: swift6
        ),
        // Byte model for the hex editor. No Penumbra, no AppKit. Umbra owns the view.
        .target(
            name: "HexKit",
            exclude: ["CLAUDE.md"],
            swiftSettings: swift6
        ),
        .executableTarget(name: "SmokeTest", dependencies: ["Penumbra", "PenumbraMarkdownLanguage"], swiftSettings: swift6),
        .executableTarget(
            name: "PerfHarness",
            dependencies: [
                "Penumbra",
                "EditorIntelligence",
                "JavaIntelligence",
                "SwiftIntelligence",
                "TypeScriptIntelligence",
                "LanguageSyntax",
                "PenumbraMarkdownLanguage",
                "PenumbraLanguages",
                "HexKit"
            ],
            path: "Tools/PerfHarness/Sources",
            swiftSettings: swift6
        ),
        // The agent evaluator: scripted tasks, a real model, a verdict from the project's own tests.
        .target(
            name: "AgentEvalKit",
            dependencies: [
                .product(name: "AgentKit", package: "AgentKit"),
                "SubprocessKit"
            ],
            path: "Tools/AgentEval/Sources/AgentEvalKit",
            swiftSettings: swift6
        ),
        .executableTarget(
            name: "AgentEval",
            dependencies: [
                "AgentEvalKit",
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "AgentKitMLX", package: "AgentKitMLX"),
                .product(name: "LocalModelStore", package: "AgentKitMLX"),
            ],
            path: "Tools/AgentEval/Sources/AgentEval",
            swiftSettings: swift6
        ),
        .testTarget(
            name: "AgentEvalTests",
            dependencies: ["AgentEvalKit", .product(name: "AgentKit", package: "AgentKit")],
            path: "Tools/AgentEval/Tests/AgentEvalTests",
            swiftSettings: swift6
        ),
        .executableTarget(
            name: "Umbra",
            dependencies: [
                "Penumbra",
                "PenumbraLanguages",
                "PenumbraMarkdownLanguage",
                "JavaIntelligence",
                "SwiftIntelligence",
                "TypeScriptIntelligence",
                "EditorIntelligenceLSP",
                "TreeSitter",
                "TreeSitterHTTP",
                "TreeSitterTypeScript",
                "TreeSitterSwift",
                "GitIntelligence",
                "SubprocessKit",
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "AgentKitMLX", package: "AgentKitMLX"),
                .product(name: "LocalModelStore", package: "AgentKitMLX"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "DiagramKit", package: "DiagramKit"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "XcodeProjectFormat", package: "xcode-project-format"),
                "HexKit"
            ],
            path: "Example/Umbra",
            exclude: [
                "CLAUDE.md",
                "SplitView/LICENSE",
                "SplitView/README.md",
                "Tools/JavaDebugAdapter/build.sh",
                "Tools/JavaDebugAdapter/build/classes",
                "Tools/JavaDebugAdapter/build/test-classes",
                "Tools/JavaDebugAdapter/build/test-sources.txt",
                "Tools/JavaDebugAdapter/build/sources.txt",
                "Tools/JavaDebugAdapter/src"
            ],
            resources: [
                .copy("Tools/JavaDebugAdapter/build/java-debug-adapter.jar"),
                .copy("../umbra.png")
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
        .target(
            name: "TreeSitterSwift",
            exclude: ["LICENSE", "VERSION", "grammar.js", "src/node-types.json"],
            cSettings: [.headerSearchPath("src")]
        ),
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
        .target(name: "TreeSitterGitIgnore", cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterGitIgnoreQueries",
            resources: [.copy("highlights.scm")]
        ),
        .target(
            name: "TreeSitterGitIgnorePenumbra",
            dependencies: ["Penumbra", "TreeSitterGitIgnore", "TreeSitterGitIgnoreQueries"],
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
                "TreeSitterDiffPenumbra",
                "TreeSitterGitIgnorePenumbra"
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
            "SwiftIntelligence",
            "TypeScriptIntelligence",
            "HexKit",
            "Umbra",
            "GitIntelligence",
            .product(name: "XcodeProjectFormat", package: "xcode-project-format"),
            .product(name: "AgentKit", package: "AgentKit"),
            .product(name: "AgentKitMLX", package: "AgentKitMLX"),
            .product(name: "LocalModelStore", package: "AgentKitMLX"),
            .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol")
        ], exclude: ["Fixtures/SwiftCorpus", "Fixtures/TypeScriptCorpus"], resources: [.copy("Fixtures/Java"), .copy("Fixtures/Gradle"), .copy("Fixtures/JavaCompletionCorpus"), .copy("Fixtures/JUnit")], swiftSettings: swift6)
    ]
)
